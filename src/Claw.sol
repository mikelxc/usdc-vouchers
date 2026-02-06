// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title Claw - Tradeable Spending Authority for AI Agents
/// @notice NFT-based bounded wallets: humans fund, agents spend, unused returns
/// @dev ERC-7978 inspired. NFT ownership = spending authority. Fully tradeable.
contract Claw is ERC721Enumerable, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    // ============ State ============

    IERC20 public immutable usdc;
    uint256 private _nextTokenId;

    struct ClawData {
        uint256 maxSpend;    // Maximum USDC (6 decimals)
        uint256 spent;       // Amount spent
        uint256 expiry;      // Unix timestamp (0 = no expiry)
        address funder;      // Original funder (receives funds on burn)
        bool burned;         // Burned status
    }

    mapping(uint256 => ClawData) public claws;

    // ============ Events ============

    event ClawMinted(
        uint256 indexed tokenId,
        address indexed funder,
        address indexed recipient,
        uint256 maxSpend,
        uint256 expiry
    );

    event ClawSpent(
        uint256 indexed tokenId,
        address indexed to,
        uint256 amount,
        uint256 remaining
    );

    event ClawBurned(
        uint256 indexed tokenId,
        address indexed returnTo,
        uint256 amountReturned
    );

    // ============ Errors ============

    error ClawExpired();
    error ClawAlreadyBurned();
    error SpendLimitExceeded();
    error NotClawOwner();
    error ZeroAmount();
    error ZeroMaxSpend();

    // ============ Constructor ============

    constructor(address _usdc) ERC721("Claw", "CLAW") Ownable(msg.sender) {
        usdc = IERC20(_usdc);
        _nextTokenId = 1;
    }

    // ============ Core Functions ============

    /// @notice Mint a new Claw - bounded spending authority as an NFT
    /// @param recipient Agent/address to receive the Claw
    /// @param maxSpend Maximum USDC spendable (transferred from caller)
    /// @param expiry Unix timestamp (0 = no expiry)
    function mint(
        address recipient,
        uint256 maxSpend,
        uint256 expiry
    ) external nonReentrant returns (uint256 tokenId) {
        if (maxSpend == 0) revert ZeroMaxSpend();
        
        usdc.safeTransferFrom(msg.sender, address(this), maxSpend);
        
        tokenId = _nextTokenId++;
        
        claws[tokenId] = ClawData({
            maxSpend: maxSpend,
            spent: 0,
            expiry: expiry,
            funder: msg.sender,
            burned: false
        });
        
        _safeMint(recipient, tokenId);
        
        emit ClawMinted(tokenId, msg.sender, recipient, maxSpend, expiry);
    }

    /// @notice Spend USDC from a Claw (only owner can spend)
    /// @param tokenId The Claw to spend from
    /// @param to Recipient of USDC
    /// @param amount Amount to spend (6 decimals)
    function spend(
        uint256 tokenId,
        address to,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (ownerOf(tokenId) != msg.sender) revert NotClawOwner();
        
        ClawData storage c = claws[tokenId];
        if (c.burned) revert ClawAlreadyBurned();
        if (c.expiry != 0 && block.timestamp > c.expiry) revert ClawExpired();
        if (c.spent + amount > c.maxSpend) revert SpendLimitExceeded();
        
        c.spent += amount;
        uint256 remaining = c.maxSpend - c.spent;
        
        usdc.safeTransfer(to, amount);
        
        emit ClawSpent(tokenId, to, amount, remaining);
    }

    /// @notice Burn a Claw and return remaining USDC to funder
    /// @param tokenId The Claw to burn
    function burn(uint256 tokenId) external nonReentrant {
        if (ownerOf(tokenId) != msg.sender) revert NotClawOwner();
        
        ClawData storage c = claws[tokenId];
        if (c.burned) revert ClawAlreadyBurned();
        
        uint256 remaining = c.maxSpend - c.spent;
        address returnTo = c.funder;
        c.burned = true;
        
        _burn(tokenId);
        
        if (remaining > 0) {
            usdc.safeTransfer(returnTo, remaining);
        }
        
        emit ClawBurned(tokenId, returnTo, remaining);
    }

    // ============ View Functions ============

    function getClaw(uint256 tokenId) external view returns (
        uint256 maxSpend,
        uint256 spent,
        uint256 remaining,
        uint256 expiry,
        address funder,
        bool burned,
        bool expired
    ) {
        ClawData storage c = claws[tokenId];
        remaining = c.maxSpend - c.spent;
        expired = c.expiry != 0 && block.timestamp > c.expiry;
        return (c.maxSpend, c.spent, remaining, c.expiry, c.funder, c.burned, expired);
    }

    function getRemaining(uint256 tokenId) external view returns (uint256) {
        ClawData storage c = claws[tokenId];
        if (c.burned || (c.expiry != 0 && block.timestamp > c.expiry)) return 0;
        return c.maxSpend - c.spent;
    }

    function isValid(uint256 tokenId) external view returns (bool) {
        try this.ownerOf(tokenId) returns (address) {
            ClawData storage c = claws[tokenId];
            if (c.burned) return false;
            if (c.expiry != 0 && block.timestamp > c.expiry) return false;
            if (c.spent >= c.maxSpend) return false;
            return true;
        } catch {
            return false;
        }
    }

    // ============ On-Chain SVG Metadata ============

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        
        ClawData storage c = claws[tokenId];
        uint256 remaining = c.maxSpend - c.spent;
        uint256 percentUsed = c.maxSpend > 0 ? (c.spent * 100) / c.maxSpend : 0;
        bool isExpired = c.expiry != 0 && block.timestamp > c.expiry;
        
        string memory status = c.burned ? "BURNED" : (isExpired ? "EXPIRED" : "ACTIVE");
        string memory statusColor = c.burned ? "#666" : (isExpired ? "#f44" : "#4f4");
        string memory barColor = c.burned ? "#333" : "#0052FF"; // Circle blue
        
        // On-chain SVG
        string memory svg = string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 250">',
            '<defs><linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">',
            '<stop offset="0%" style="stop-color:#1a1a2e"/><stop offset="100%" style="stop-color:#16213e"/></linearGradient></defs>',
            '<rect width="400" height="250" fill="url(#bg)" rx="20"/>',
            '<text x="30" y="45" font-family="Arial" font-size="24" font-weight="bold" fill="#fff">CLAW #', tokenId.toString(), '</text>',
            '<text x="30" y="75" font-family="Arial" font-size="14" fill="#888">Spending Authority</text>',
            _renderBalance(remaining, c.maxSpend),
            _renderProgressBar(percentUsed, barColor),
            '<text x="30" y="200" font-family="Arial" font-size="12" fill="#888">Status: </text>',
            '<text x="80" y="200" font-family="Arial" font-size="12" fill="', statusColor, '">', status, '</text>',
            _renderExpiry(c.expiry, isExpired),
            '<text x="370" y="230" font-family="Arial" font-size="10" fill="#444" text-anchor="end">USDC on Base</text>',
            '</svg>'
        ));
        
        string memory json = string(abi.encodePacked(
            '{"name":"Claw #', tokenId.toString(),
            '","description":"Tradeable bounded spending authority for AI agents. Humans fund, agents spend, unused returns.",',
            '"image":"data:image/svg+xml;base64,', Base64.encode(bytes(svg)), '",',
            '"attributes":[',
            '{"trait_type":"Max Spend","value":"', _formatUSDC(c.maxSpend), ' USDC"},',
            '{"trait_type":"Spent","value":"', _formatUSDC(c.spent), ' USDC"},',
            '{"trait_type":"Remaining","value":"', _formatUSDC(remaining), ' USDC"},',
            '{"trait_type":"Status","value":"', status, '"},',
            '{"trait_type":"Percent Used","display_type":"number","value":', percentUsed.toString(), '}',
            ']}'
        ));
        
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    function _renderBalance(uint256 remaining, uint256 max) internal pure returns (string memory) {
        return string(abi.encodePacked(
            '<text x="30" y="130" font-family="Arial" font-size="42" font-weight="bold" fill="#fff">$',
            _formatUSDC(remaining),
            '</text>',
            '<text x="30" y="155" font-family="Arial" font-size="14" fill="#888">of $',
            _formatUSDC(max),
            ' remaining</text>'
        ));
    }

    function _renderProgressBar(uint256 percentUsed, string memory color) internal pure returns (string memory) {
        uint256 barWidth = (340 * percentUsed) / 100;
        return string(abi.encodePacked(
            '<rect x="30" y="165" width="340" height="8" fill="#333" rx="4"/>',
            '<rect x="30" y="165" width="', barWidth.toString(), '" height="8" fill="', color, '" rx="4"/>'
        ));
    }

    function _renderExpiry(uint256 expiry, bool isExpired) internal pure returns (string memory) {
        if (expiry == 0) {
            return '<text x="30" y="220" font-family="Arial" font-size="12" fill="#888">No expiry</text>';
        }
        string memory color = isExpired ? "#f44" : "#888";
        return string(abi.encodePacked(
            '<text x="30" y="220" font-family="Arial" font-size="12" fill="', color, '">Expires: ', expiry.toString(), '</text>'
        ));
    }

    function _formatUSDC(uint256 amount) internal pure returns (string memory) {
        uint256 whole = amount / 1e6;
        uint256 fraction = (amount % 1e6) / 1e4; // 2 decimal places
        if (fraction == 0) {
            return whole.toString();
        }
        return string(abi.encodePacked(whole.toString(), ".", fraction < 10 ? "0" : "", fraction.toString()));
    }

    // ============ Transfer Hook ============

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (to == address(this)) revert("Cannot transfer to contract");
        return super._update(to, tokenId, auth);
    }
}
