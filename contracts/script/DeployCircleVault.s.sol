// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {CircleVault} from "../src/CircleVault.sol";
import {ERC20Claim} from "../src/ERC20Claim.sol";

contract DeployCircleVault is Script {
    // USDC on Base Sepolia: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
    address constant USDC_BASE_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        ERC20Claim share = new ERC20Claim("Mandinga Claim", "MCLM", msg.sender);

        CircleVault.CircleParams memory params = CircleVault.CircleParams({
            name: "Mandinga Circle",
            targetValue: 20_000e6, // 20,000 USDC (6 decimals)
            totalInstallments: 24,
            startTimestamp: block.timestamp,
            totalDurationDays: 720, // ~2 years
            timePerRound: 30 days,
            numRounds: 3,
            numUsers: 100,
            exitFeeBps: 100,
            paymentToken: USDC_BASE_SEPOLIA,
            shareToken: address(share),
            positionNft: address(0), // TODO: deploy PositionNFT first
            quotaCapEarly: 34,
            quotaCapMiddle: 33,
            quotaCapLate: 33,
            drawConsumer: address(0) // TODO: deploy DrawConsumer first
        });

        CircleVault vault = new CircleVault(params, msg.sender);
        share.transferOwnership(address(vault));
        // console.log("CircleVault deployed at:", address(vault));

        vm.stopBroadcast();
    }
}
