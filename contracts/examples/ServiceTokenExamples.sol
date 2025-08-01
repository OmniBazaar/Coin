// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {UnifiedNFTMarketplace} from "../UnifiedNFTMarketplace.sol";

/**
 * @title ServiceTokenExamples
 * @author OmniBazaar Team
 * @notice Example implementations for common service token use cases
 * @dev These examples demonstrate how to create various types of service tokens
 * using the UnifiedNFTMarketplace's ERC1155 functionality
 */
contract ServiceTokenExamples {
    
    /// @notice The UnifiedNFTMarketplace contract
    UnifiedNFTMarketplace public immutable MARKETPLACE;
    
    /**
     * @notice Constructor to set the marketplace contract
     * @param _marketplace Address of the UnifiedNFTMarketplace contract
     */
    constructor(address _marketplace) {
        MARKETPLACE = UnifiedNFTMarketplace(_marketplace);
    }
    
    // =============================================================================
    // EXAMPLE 1: Hourly Consultation Service
    // =============================================================================
    
    /**
     * @notice Create consultation hour tokens
     * @param consultationHours Number of consultation hours to tokenize
     * @param pricePerHour Price per hour in XOM (6 decimals)
     * @param validityDays How many days the tokens are valid
     * @return tokenId The ID of the created token
     */
    function createConsultationTokens(
        uint256 consultationHours,
        uint256 pricePerHour,
        uint256 validityDays
    ) external returns (uint256 tokenId) {
        string memory metadata = string(abi.encodePacked(
            "ipfs://QmConsultation/",
            "{\"name\":\"1-Hour Consultation\",",
            "\"description\":\"Redeemable for 1 hour of professional consultation\",",
            "\"image\":\"ipfs://consultation-icon\",",
            "\"attributes\":[",
            "{\"trait_type\":\"Service Type\",\"value\":\"Consultation\"},",
            "{\"trait_type\":\"Duration\",\"value\":\"1 hour\"},",
            "{\"trait_type\":\"Validity\",\"value\":\"", toString(validityDays), " days\"}",
            "]}"
        ));
        
        tokenId = MARKETPLACE.createServiceToken(
            consultationHours,
            validityDays * 1 days,
            metadata,
            pricePerHour
        );
    }
    
    // =============================================================================
    // EXAMPLE 2: Subscription-based Service (Weekly Produce Box)
    // =============================================================================
    
    /**
     * @notice Create weekly produce box subscription tokens
     * @param numWeeks Number of weekly boxes to tokenize
     * @param pricePerBox Price per box in XOM
     * @return tokenId The ID of the created token
     */
    function createProduceBoxTokens(
        uint256 numWeeks,
        uint256 pricePerBox
    ) external returns (uint256 tokenId) {
        string memory metadata = string(abi.encodePacked(
            "ipfs://QmProduceBox/",
            "{\"name\":\"Weekly Organic Produce Box\",",
            "\"description\":\"One weekly delivery of fresh organic produce\",",
            "\"image\":\"ipfs://produce-box-image\",",
            "\"attributes\":[",
            "{\"trait_type\":\"Service Type\",\"value\":\"Subscription\"},",
            "{\"trait_type\":\"Frequency\",\"value\":\"Weekly\"},",
            "{\"trait_type\":\"Contents\",\"value\":\"Seasonal organic vegetables\"}",
            "]}"
        ));
        
        tokenId = MARKETPLACE.createServiceToken(
            numWeeks,
            7 days, // Valid for 1 week per token
            metadata,
            pricePerBox
        );
    }
    
    // =============================================================================
    // EXAMPLE 3: Software License with Support
    // =============================================================================
    
    /**
     * @notice Create software license tokens with support period
     * @param licenses Number of licenses to create
     * @param pricePerLicense Price per license
     * @param supportDays Days of support included
     * @return tokenId The ID of the created token
     */
    function createSoftwareLicenseTokens(
        uint256 licenses,
        uint256 pricePerLicense,
        uint256 supportDays
    ) external returns (uint256 tokenId) {
        string memory metadata = string(abi.encodePacked(
            "ipfs://QmSoftwareLicense/",
            "{\"name\":\"Software License + Support\",",
            "\"description\":\"Perpetual software license with ", toString(supportDays), " days support\",",
            "\"image\":\"ipfs://software-icon\",",
            "\"attributes\":[",
            "{\"trait_type\":\"License Type\",\"value\":\"Perpetual\"},",
            "{\"trait_type\":\"Support Duration\",\"value\":\"", toString(supportDays), " days\"},",
            "{\"trait_type\":\"Updates\",\"value\":\"Included\"}",
            "]}"
        ));
        
        tokenId = MARKETPLACE.createToken(
            licenses,
            UnifiedNFTMarketplace.TokenType.SEMI_FUNGIBLE,
            metadata,
            1000 // 10% royalty on resales
        );
        
        // List the tokens for sale
        MARKETPLACE.createListing(
            tokenId,
            licenses,
            pricePerLicense,
            false // No privacy for software licenses
        );
    }
    
    // =============================================================================
    // EXAMPLE 4: Gym Membership Tokens
    // =============================================================================
    
    /**
     * @notice Create monthly gym membership tokens
     * @param memberships Number of memberships
     * @param monthlyPrice Price per month
     * @return tokenId The ID of the created token
     */
    function createGymMembershipTokens(
        uint256 memberships,
        uint256 monthlyPrice
    ) external returns (uint256 tokenId) {
        string memory metadata = string(abi.encodePacked(
            "ipfs://QmGymMembership/",
            "{\"name\":\"Monthly Gym Membership\",",
            "\"description\":\"Full access to gym facilities for 30 days\",",
            "\"image\":\"ipfs://gym-membership-card\",",
            "\"attributes\":[",
            "{\"trait_type\":\"Access Level\",\"value\":\"Full\"},",
            "{\"trait_type\":\"Duration\",\"value\":\"30 days\"},",
            "{\"trait_type\":\"Facilities\",\"value\":\"All locations\"}",
            "]}"
        ));
        
        tokenId = MARKETPLACE.createServiceToken(
            memberships,
            30 days,
            metadata,
            monthlyPrice
        );
    }
    
    // =============================================================================
    // EXAMPLE 5: Event Tickets (Multiple Tiers)
    // =============================================================================
    
    /**
     * @notice Create tiered event tickets (general and VIP)
     * @param generalTickets Number of general admission tickets
     * @param vipTickets Number of VIP tickets
     * @param generalPrice Price for general admission
     * @param vipPrice Price for VIP tickets
     * @param eventDate Unix timestamp of the event
     * @return generalId ID of general admission tokens
     * @return vipId ID of VIP tokens
     */
    function createEventTickets(
        uint256 generalTickets,
        uint256 vipTickets,
        uint256 generalPrice,
        uint256 vipPrice,
        uint256 eventDate
    ) external returns (uint256 generalId, uint256 vipId) {
        // General admission tickets
        string memory generalMetadata = string(abi.encodePacked(
            "ipfs://QmEventGeneral/",
            "{\"name\":\"Concert Ticket - General Admission\",",
            "\"description\":\"General admission to the concert\",",
            "\"image\":\"ipfs://ticket-general\",",
            "\"attributes\":[",
            "{\"trait_type\":\"Tier\",\"value\":\"General\"},",
            "{\"trait_type\":\"Event Date\",\"value\":\"", toString(eventDate), "\"},",
            "{\"trait_type\":\"Transferable\",\"value\":\"Yes\"}",
            "]}"
        ));
        
        generalId = MARKETPLACE.createServiceToken(
            generalTickets,
            eventDate + 1 days - block.timestamp, // solhint-disable-line not-rely-on-time
            generalMetadata,
            generalPrice
        );
        
        // VIP tickets
        string memory vipMetadata = string(abi.encodePacked(
            "ipfs://QmEventVIP/",
            "{\"name\":\"Concert Ticket - VIP\",",
            "\"description\":\"VIP access with backstage pass\",",
            "\"image\":\"ipfs://ticket-vip\",",
            "\"attributes\":[",
            "{\"trait_type\":\"Tier\",\"value\":\"VIP\"},",
            "{\"trait_type\":\"Event Date\",\"value\":\"", toString(eventDate), "\"},",
            "{\"trait_type\":\"Perks\",\"value\":\"Backstage access, Premium seating\"}",
            "]}"
        ));
        
        vipId = MARKETPLACE.createServiceToken(
            vipTickets,
            eventDate + 1 days - block.timestamp, // solhint-disable-line not-rely-on-time
            vipMetadata,
            vipPrice
        );
    }
    
    // =============================================================================
    // EXAMPLE 6: Handmade Product Vouchers
    // =============================================================================
    
    /**
     * @notice Create vouchers for handmade products
     * @param initialStock Initial number of vouchers
     * @param pricePerItem Price per item
     * @param productionTime Days needed to produce after order
     * @return tokenId The ID of the created token
     */
    function createHandmadeCraftTokens(
        uint256 initialStock,
        uint256 pricePerItem,
        uint256 productionTime
    ) external returns (uint256 tokenId) {
        string memory metadata = string(abi.encodePacked(
            "ipfs://QmHandmadeCraft/",
            "{\"name\":\"Handmade Ceramic Mug\",",
            "\"description\":\"Custom handmade ceramic mug, made to order\",",
            "\"image\":\"ipfs://ceramic-mug-sample\",",
            "\"attributes\":[",
            "{\"trait_type\":\"Material\",\"value\":\"Ceramic\"},",
            "{\"trait_type\":\"Production Time\",\"value\":\"", toString(productionTime), " days\"},",
            "{\"trait_type\":\"Customizable\",\"value\":\"Yes\"}",
            "]}"
        ));
        
        tokenId = MARKETPLACE.createToken(
            initialStock,
            UnifiedNFTMarketplace.TokenType.SEMI_FUNGIBLE,
            metadata,
            500 // 5% royalty for artist
        );
        
        // List tokens at specified price
        MARKETPLACE.createListing(
            tokenId,
            initialStock,
            pricePerItem,
            true // Accept privacy payments for handmade items
        );
    }
    
    // =============================================================================
    // EXAMPLE 7: Fungible Reward Points
    // =============================================================================
    
    /**
     * @notice Create fungible reward points that can be traded
     * @param initialSupply Initial supply of points
     * @param pointValue Value per point in XOM
     * @return tokenId The ID of the created token
     */
    function createRewardPoints(
        uint256 initialSupply,
        uint256 pointValue
    ) external returns (uint256 tokenId) {
        string memory metadata = string(abi.encodePacked(
            "ipfs://QmRewardPoints/",
            "{\"name\":\"OmniBazaar Reward Points\",",
            "\"description\":\"Tradeable reward points for the OmniBazaar ecosystem\",",
            "\"image\":\"ipfs://reward-points-icon\",",
            "\"attributes\":[",
            "{\"trait_type\":\"Type\",\"value\":\"Fungible\"},",
            "{\"trait_type\":\"Redeemable\",\"value\":\"Yes\"},",
            "{\"trait_type\":\"Transferable\",\"value\":\"Yes\"}",
            "]}"
        ));
        
        tokenId = MARKETPLACE.createToken(
            initialSupply,
            UnifiedNFTMarketplace.TokenType.FUNGIBLE,
            metadata,
            0 // No royalties on fungible tokens
        );
        
        if (pointValue > 0) {
            // List some points for sale
            uint256 listAmount = initialSupply / 10; // List 10% initially
            MARKETPLACE.createListing(
                tokenId,
                listAmount,
                pointValue,
                false
            );
        }
    }
    
    // =============================================================================
    // EXTERNAL VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Check if user has valid service for a token
     * @param user The user address to check
     * @param tokenId The service token ID
     * @return isValid Whether the service is currently valid
     */
    function checkServiceValidity(
        address user,
        uint256 tokenId
    ) external view returns (bool isValid) {
        return MARKETPLACE.isServiceValid(user, tokenId);
    }
    
    /**
     * @notice Get token balance and listing info
     * @param tokenId The token ID to check
     * @return userBalance The caller's balance
     * @return listedAmount Amount currently listed
     * @return price Current price per unit
     */
    function getTokenStatus(uint256 tokenId) external view returns (
        uint256 userBalance,
        uint256 listedAmount,
        uint256 price
    ) {
        userBalance = MARKETPLACE.balanceOf(msg.sender, tokenId);
        listedAmount = MARKETPLACE.getActiveListing(tokenId);
        
        (,,,price,,,) = MARKETPLACE.getTokenInfo(tokenId);
    }

    // =============================================================================
    // INTERNAL UTILITY FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Convert uint256 to string
     * @param value The value to convert
     * @return The string representation
     */
    function toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            ++digits;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            --digits;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}