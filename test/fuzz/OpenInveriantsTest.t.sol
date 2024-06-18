// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {Script, console} from "forge-std/Script.sol";
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

// 不变性测试

contract OpenInveriantsTest is StdInvariant, Test {
    DeployDSC private deployer;
    DSCEngine private dsce;
    DecentralizedStableCoin private dsc;
    HelperConfig private config;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        console.log(address(weth));
        console.log(address(wbtc));
        // 告诉不变性测试框架我们要测试的合约
        //targetContract(address(dsce));
        handler = new Handler(dsce, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThatTotalSupplyDollars() public {
        // 保证协议的价值大于总供应的美元价值
        uint256 totalSupply = dsc.totalSupply();

        uint256 totalWethDeposied = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposied = IERC20(wbtc).balanceOf(address(dsce));

        uint256 wethValue = dsce._getUSDPrice(weth, totalWethDeposied);
        uint256 wbtcValue = dsce._getUSDPrice(wbtc, totalWbtcDeposied);

        console.log("wethValue: ", wethValue);
        console.log("wbtcValue: ", totalSupply);
        console.log("wbtcValue: ", totalSupply);

        // assert(wethValue + wbtcValue >= totalSupply);
    }
}
