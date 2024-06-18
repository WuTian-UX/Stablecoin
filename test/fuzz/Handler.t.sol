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
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

// 不变性测试

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;

    constructor(DSCEngine _dsce, DecentralizedStableCoin _dsc) {
        dsce = _dsce;
        dsc = _dsc;
        address[] memory collTocollateralTokenskens = dsce.getCollateralTokens();
        weth = ERC20Mock(collTocollateralTokenskens[0]);
        wbtc = ERC20Mock(collTocollateralTokenskens[1]);
    }

    // collateral 抵押品地址
    // amountcollateral 抵押品数量
    // function depositCollateral(address collateral, uint256 amountcollateral) public {  // 这样写的话，collateral 抵押品地址是全随机值，大部分会报错
    function depositCollateral(uint256 collateralSeed, uint256 amountcollateral) public {
        console.log(3);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        dsce.depositCollateral(address(collateral), amountcollateral);
    }

    // 随机一个能用的抵押品
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        return collateralSeed % 2 == 0 ? weth : wbtc;
    }
}
