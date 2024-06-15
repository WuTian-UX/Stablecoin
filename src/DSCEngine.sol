// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
// 导入不可重入保护
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// 喂价
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// 稳定币 超额抵押
contract DSCEngine is ReentrancyGuard {
    //////////////
    // 错误定义 //
    //////////////

    error DSCEngine_AmountMustBeMoreThanZero(); // 数量必须大于0
    error DSCEngine_TokenNotAllowed(address token); // token不允许
    error DSCEngine_TokenAddressesAndPriceFeedAddressesAmountsDontMatch(); // TokenAddresses和priceFeedAddresses长度不匹配
    error DSCEngine__TransferFailed();

    ///////////////////////
    // 状态变量定义       //
    ///////////////////////

    DecentralizedStableCoin private immutable i_dsc; // 稳定币

    address[] private s_collateralTokens; // 抵押物地址 数组 (抵押物地址有循环需求，所以只有mapping不够用)
    mapping(address collateralToken => address priceFeed) private s_priceFeeds; // 抵押物地址 => 价格预言机地址
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // 用户抵押物数量
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted; // 用户铸造的稳定币数量

    uint256 private constant PRECISION = 1e18; // 精度
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10; // 额外的精度
    uint256 private constant FEED_PRECISION = 1e8; // 预言机精度
    ///////////////////////
    // 事件定义       //
    ///////////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount); // 抵押物存入

    ///////////////////////
    // 修饰器定义       //
    ///////////////////////

    // 修饰器 限制数量必须大于0
    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine_AmountMustBeMoreThanZero();
        }
        _; // 占位符 表示修饰器修饰的函数主体将在此处执行
    }

    // 修饰器 限制token必须是允许的
    modifier isAllowedToken(address _token) {
        if (s_priceFeeds[_token] == address(0)) {
            revert DSCEngine_TokenNotAllowed(_token);
        }
        _;
    }

    ///////////////////////
    // 函数定义     //
    ///////////////////////

    // 构造函数
    constructor(
        address[] memory _TokenAddresses, // 抵押物地址
        address[] memory _priceFeedAddresses, // 价格预言机地址
        address _dscAddress // 稳定币地址
    ) {
        if (_TokenAddresses.length != _priceFeedAddresses.length) {
            revert DSCEngine_TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
        }
        for (uint256 i = 0; i < _TokenAddresses.length; i++) {
            s_priceFeeds[_TokenAddresses[i]] = _priceFeedAddresses[i];
            s_collateralTokens.push(_TokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(_dscAddress);
    }

    ///////////////////////
    // 外部函数定义       //
    ///////////////////////
    function depositCollateralAndMintDsc() external {}

    // 从外部合约中存入抵押物
    function depositCollateral(
        address tokenCollateralAddress, // 抵押物地址
        uint256 aoumntCollateral // 抵押物数量
    )
        external
        moreThanZero(aoumntCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant // 不可重入
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += aoumntCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, aoumntCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), aoumntCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function depositCollateralForDSC() external {}

    // 铸造稳定币
    // 先检查抵押物是否足够 必须比最低阈值大
    function mintDSC(uint256 amountDscToMint) external moreThanZero(amountDscToMint) nonReentrant {
        // 1. 检查抵押物是否足够
        // 2. 铸造稳定币
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDsc() external {}

    // 清算
    function liquidate() external {}

    // 获取健康情况
    function getHeleathFactor() external view {}

    ///////////////////////
    // 内部函数定义       //
    ///////////////////////
    function _revertIfHealthFactorIsBroken(address user) internal view {}

    // 获取用户健康因子
    function _healthFactor(address user) internal view returns (uint256) {
        // 计算健康因子 需要的参数
        // 总dsc
        // 总抵押物价值
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
    }

    // 获取用户信息
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = _getAccountCollateralValue(user);
    }

    function _getAccountCollateralValue(address user) private view returns (uint256) {
        uint256 totalCollateralValueInUsd = 0;
        // 遍历每种抵押物
        // 计算该用户抵押的，每种抵押物的价值之和
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUSDPrice(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function _getUSDPrice(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}
