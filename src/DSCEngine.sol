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

    error DSCEngine_HealthFactorBelowMinimum(uint256 healthFactor); // 健康因子低于最小值
    error DSCEngine_MintedFailed(); // 铸造失败

    error DSCEngine__TransferFailed(); // 转账失败

    error DSCEngine_HealthFactorOK(uint256 healthFactor); // 健康因子低于最小值
    error DSCEngine_HealthFactorNotImproved(uint256 healthFactor); // 健康因子低于最小值
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
    uint256 private constant MIN_HEALTH_FACTOR = 1; // 最小健康因子

    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 清算阈值
    uint256 private constant LIQUIDATION_PRECISION = 100; // 清算精度

    uint256 private constant LIQUIDATION_BONUS = 10; // 清算奖励
    ///////////////////////
    // 事件定义       //
    ///////////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount); // 抵押物存入

    event CollateralRedeemed(address indexed user, address token, uint256 amount); // 抵押物赎回
    // if
    // redeemFrom != redeemedTo, then it was liquidated

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

    // 从USD中获取token数量
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData(); // 获取最新价格
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    // 存入抵押物并铸造稳定币
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress, // 抵押物地址
        uint256 aoumntCollateral, // 抵押物数量
        uint256 amountDscToMint // 铸造稳定币数量
    ) external {
        depositCollateral(tokenCollateralAddress, aoumntCollateral);
        mintDSC(amountDscToMint);
    }

    // 从外部合约中存入抵押物
    function depositCollateral(
        address tokenCollateralAddress, // 抵押物地址
        uint256 aoumntCollateral // 抵押物数量
    )
        public
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

    // 赎回抵押物
    // 赎回后健康因子必须大于最小值
    function redeemCollateral(
        address tokenCollateralAddress, // 抵押物地址
        uint256 amountCollateral // 抵押物数量
    )
        public
        moreThanZero(amountCollateral) // 数量必须大于0
        nonReentrant // 不可重入
        isAllowedToken(tokenCollateralAddress)
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _redeemCollateral(
        address tokenCollateralAddress, // 抵押物地址
        uint256 amountCollateral, // 抵押物数量
        address from,
        address to
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }
    // 赎回抵押物换取稳定币

    function redeemCollateralForDsc(
        address tokenCollateralAddress, // 抵押物地址
        uint256 amountCollateral, // 抵押物数量
        uint256 amountDscToBurn // 烧毁稳定币数量
    ) public {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    function getUsdValue(
        address token,
        uint256 amount // in WEI
    ) external view returns (uint256) {
        return _getUSDPrice(token, amount);
    }

    // 铸造稳定币
    // 先检查抵押物是否足够 必须比最低阈值大

    function mintDSC(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        // 1. 检查抵押物是否足够
        // 2. 铸造稳定币
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine_MintedFailed();
        }
    }

    // 烧毁稳定币
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // 清算
    // 帮一个用户清算
    function liquidate(
        address collateral, // 抵押物
        address user, // 被发起清算的用户
        uint256 debtToCover // 需要清算的债务
    ) external moreThanZero(debtToCover) nonReentrant {
        // 假设清算用户 用140美元的eth 拿走了100美元的稳定币？
        // 假设债务为100美元
        // 100美元稳定币=多少eth？
        // 给予额外的10%的奖励

        // 确认被清算用户的健康因子是否低于最小值
        uint256 startingUserHeleathFactor = _healthFactor(user);
        if (startingUserHeleathFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorOK(startingUserHeleathFactor);
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        // 假设0.05eth 奖励是0.005eth
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);

        _burnDsc(debtToCover, user, msg.sender);

        uint256 enddingUserHeleathFactor = _healthFactor(user);
        if (enddingUserHeleathFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorNotImproved(startingUserHeleathFactor);
        }

        //如果因为清算，破坏了发起清算者的健康因子，那么我们应该抛出异常
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // 获取健康情况
    function getHeleathFactor() external view {}

    ///////////////////////
    // 内部函数定义       //
    ///////////////////////
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorBelowMinimum(healthFactor);
        }
    }

    // 获取用户健康因子
    function _healthFactor(address user) internal view returns (uint256) {
        // 计算健康因子 需要的参数
        // 总dsc
        // 总抵押物价值
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = getAccountInformation(user);

        // 计算健康因子
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }
    // 获取用户信息

    function getAccountInformation(address user)
        public
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

    // 获取一种代币的USD价格
    function _getUSDPrice(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;

        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // This conditional is hypothetically unreachable
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }
}
