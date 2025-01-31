// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "./libs/rocketswap-lib/token/BEP20/IBEP20.sol";
import "./libs/rocketswap-lib/token/BEP20/SafeBEP20.sol";
import "./interfaces/IMasterRefiner.sol";
import "./libs/rocketswap-lib/access/Ownable.sol";
import "./libs/rocketswap-lib/security/Pausable.sol";

contract RefineryVault is Ownable, Pausable {
    using SafeBEP20 for IBEP20;

    struct UserInfo {
        uint256 shares; // number of shares for a user
        uint256 lastDepositedTime; // keeps track of deposited time for potential penalty
        uint256 refineryAtLastUserAction; // keeps track of refinery deposited at the last user action
        uint256 lastUserActionTime; // keeps track of the last user action time
    }

    IBEP20 public immutable token; // Refinery token
    IBEP20 public immutable receiptToken; // Fuel token

    IMasterRefiner public immutable masterRefiner;

    mapping(address => UserInfo) public userInfo;

    uint256 public totalShares;
    uint256 public lastHarvestedTime;
    address public admin;
    address public treasury;

    uint256 public constant MAX_PERFORMANCE_FEE = 500; // 5%
    uint256 public constant MAX_CALL_FEE = 100; // 1%
    uint256 public constant MAX_WITHDRAW_FEE = 100; // 1%
    uint256 public constant MAX_WITHDRAW_FEE_PERIOD = 72 hours; // 3 days

    uint256 public performanceFee = 200; // 2%
    uint256 public callFee = 25; // 0.25%
    uint256 public withdrawFee = 10; // 0.1%
    uint256 public withdrawFeePeriod = 72 hours; // 3 days

    event Deposit(
        address indexed sender,
        uint256 amount,
        uint256 shares,
        uint256 lastDepositedTime
    );
    event Withdraw(address indexed sender, uint256 amount, uint256 shares);
    event Harvest(
        address indexed sender,
        uint256 performanceFee,
        uint256 callFee
    );
    event Pause();
    event Unpause();

    /**
     * @notice Constructor
     * @param _token: Refinery token contract
     * @param _receiptToken: Fuel token contract
     * @param _masterRefiner: MasterRefinery contract
     * @param _admin: address of the admin
     * @param _treasury: address of the treasury (collects fees)
     */
    constructor(
        IBEP20 _token,
        IBEP20 _receiptToken,
        IMasterRefiner _masterRefiner,
        address _admin,
        address _treasury
    ) {
        token = _token;
        receiptToken = _receiptToken;
        masterRefiner = _masterRefiner;
        admin = _admin;
        treasury = _treasury;

        // Infinite approve
        IBEP20(_token).safeApprove(address(_masterRefiner), type(uint256).max);
    }

    /**
     * @notice Checks if the msg.sender is the admin address
     */
    modifier onlyAdmin() {
        require(msg.sender == admin, "admin: wut?");
        _;
    }

    /**
     * @notice Checks if the msg.sender is a contract or a proxy
     */
    modifier notContract() {
        require(!_isContract(msg.sender), "contract not allowed");
        require(msg.sender == tx.origin, "proxy contract not allowed");
        _;
    }

    /**
     * @notice Deposits funds into the Refinery Vault
     * @dev Only possible when contract not paused.
     * @param _amount: number of tokens to deposit (in REFINERY)
     */
    function deposit(uint256 _amount) external whenNotPaused notContract {
        require(_amount > 0, "Nothing to deposit");

        uint256 pool = balanceOf();
        token.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 currentShares = 0;
        if (totalShares != 0) {
            currentShares = (_amount * totalShares) / pool;
        } else {
            currentShares = _amount;
        }
        UserInfo storage user = userInfo[msg.sender];

        user.shares = user.shares + currentShares;
        user.lastDepositedTime = block.timestamp;

        totalShares = totalShares + currentShares;

        user.refineryAtLastUserAction = (user.shares * balanceOf()) / totalShares;
        user.lastUserActionTime = block.timestamp;

        _earn();

        emit Deposit(msg.sender, _amount, currentShares, block.timestamp);
    }

    /**
     * @notice Withdraws all funds for a user
     */
    function withdrawAll() external notContract {
        withdraw(userInfo[msg.sender].shares);
    }

    /**
     * @notice Reinvests REFINERY tokens into MasterRefinery
     * @dev Only possible when contract not paused.
     */
    function harvest() external notContract whenNotPaused {
        IMasterRefiner(masterRefiner).leaveStaking(0);

        uint256 bal = available();
        uint256 currentPerformanceFee = (bal * performanceFee) / 10000;
        token.safeTransfer(treasury, currentPerformanceFee);

        uint256 currentCallFee = (bal * callFee) / 10000;
        token.safeTransfer(msg.sender, currentCallFee);

        _earn();

        lastHarvestedTime = block.timestamp;

        emit Harvest(msg.sender, currentPerformanceFee, currentCallFee);
    }

    /**
     * @notice Sets admin address
     * @dev Only callable by the contract owner.
     */
    function setAdmin(address _admin) external onlyOwner {
        require(_admin != address(0), "Cannot be zero address");
        admin = _admin;
    }

    /**
     * @notice Sets treasury address
     * @dev Only callable by the contract owner.
     */
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Cannot be zero address");
        treasury = _treasury;
    }

    /**
     * @notice Sets performance fee
     * @dev Only callable by the contract admin.
     */
    function setPerformanceFee(uint256 _performanceFee) external onlyAdmin {
        require(
            _performanceFee <= MAX_PERFORMANCE_FEE,
            "performanceFee cannot be more than MAX_PERFORMANCE_FEE"
        );
        performanceFee = _performanceFee;
    }

    /**
     * @notice Sets call fee
     * @dev Only callable by the contract admin.
     */
    function setCallFee(uint256 _callFee) external onlyAdmin {
        require(
            _callFee <= MAX_CALL_FEE,
            "callFee cannot be more than MAX_CALL_FEE"
        );
        callFee = _callFee;
    }

    /**
     * @notice Sets withdraw fee
     * @dev Only callable by the contract admin.
     */
    function setWithdrawFee(uint256 _withdrawFee) external onlyAdmin {
        require(
            _withdrawFee <= MAX_WITHDRAW_FEE,
            "withdrawFee cannot be more than MAX_WITHDRAW_FEE"
        );
        withdrawFee = _withdrawFee;
    }

    /**
     * @notice Sets withdraw fee period
     * @dev Only callable by the contract admin.
     */
    function setWithdrawFeePeriod(uint256 _withdrawFeePeriod)
        external
        onlyAdmin
    {
        require(
            _withdrawFeePeriod <= MAX_WITHDRAW_FEE_PERIOD,
            "withdrawFeePeriod cannot be more than MAX_WITHDRAW_FEE_PERIOD"
        );
        withdrawFeePeriod = _withdrawFeePeriod;
    }

    /**
     * @notice Withdraws from MasterRefinery to Vault without caring about rewards.
     * @dev EMERGENCY ONLY. Only callable by the contract admin.
     */
    function emergencyWithdraw() external onlyAdmin {
        IMasterRefiner(masterRefiner).emergencyWithdraw(0);
    }

    /**
     * @notice Withdraw unexpected tokens sent to the Refinery Vault
     */
    function inCaseTokensGetStuck(address _token) external onlyAdmin {
        require(
            _token != address(token),
            "Token cannot be same as deposit token"
        );
        require(
            _token != address(receiptToken),
            "Token cannot be same as receipt token"
        );

        uint256 amount = IBEP20(_token).balanceOf(address(this));
        IBEP20(_token).safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Triggers stopped state
     * @dev Only possible when contract not paused.
     */
    function pause() external onlyAdmin whenNotPaused {
        _pause();
        emit Pause();
    }

    /**
     * @notice Returns to normal state
     * @dev Only possible when contract is paused.
     */
    function unpause() external onlyAdmin whenPaused {
        _unpause();
        emit Unpause();
    }

    /**
     * @notice Calculates the expected harvest reward from third party
     * @return Expected reward to collect in REFINERY
     */
    function calculateHarvestRefineryRewards() external view returns (uint256) {
        uint256 amount = IMasterRefiner(masterRefiner).pendingRP1(
            0,
            address(this)
        );
        amount = amount + available();
        uint256 currentCallFee = (amount * callFee) / 10000;

        return currentCallFee;
    }

    /**
     * @notice Calculates the total pending rewards that can be restaked
     * @return Returns total pending refinery rewards
     */
    function calculateTotalPendingRefineryRewards()
        external
        view
        returns (uint256)
    {
        uint256 amount = IMasterRefiner(masterRefiner).pendingRP1(
            0,
            address(this)
        );
        amount = amount + available();

        return amount;
    }

    /**
     * @notice Calculates the price per share
     */
    function getPricePerFullShare() external view returns (uint256) {
        return totalShares == 0 ? 1e18 : (balanceOf() * 1e18) / totalShares;
    }

    /**
     * @notice Withdraws from funds from the Refinery Vault
     * @param _shares: Number of shares to withdraw
     */
    function withdraw(uint256 _shares) public notContract {
        UserInfo storage user = userInfo[msg.sender];
        require(_shares > 0, "Nothing to withdraw");
        require(_shares <= user.shares, "Withdraw amount exceeds balance");

        uint256 currentAmount = (balanceOf() * _shares) / totalShares;
        user.shares = user.shares - _shares;
        totalShares = totalShares - _shares;

        uint256 bal = available();
        if (bal < currentAmount) {
            uint256 balWithdraw = currentAmount - bal;
            IMasterRefiner(masterRefiner).leaveStaking(balWithdraw);
            uint256 balAfter = available();
            uint256 diff = balAfter - bal;
            if (diff < balWithdraw) {
                currentAmount = bal + diff;
            }
        }

        if (block.timestamp < user.lastDepositedTime + withdrawFeePeriod) {
            uint256 currentWithdrawFee = (currentAmount * withdrawFee) / 10000;
            token.safeTransfer(treasury, currentWithdrawFee);
            currentAmount = currentAmount - currentWithdrawFee;
        }

        if (user.shares > 0) {
            user.refineryAtLastUserAction = (user.shares * balanceOf()) / totalShares;
        } else {
            user.refineryAtLastUserAction = 0;
        }

        user.lastUserActionTime = block.timestamp;

        token.safeTransfer(msg.sender, currentAmount);

        emit Withdraw(msg.sender, currentAmount, _shares);
    }

    /**
     * @notice Custom logic for how much the vault allows to be borrowed
     * @dev The contract puts 100% of the tokens to work.
     */
    function available() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /**
     * @notice Calculates the total underlying tokens
     * @dev It includes tokens held by the contract and held in MasterRefinery
     */
    function balanceOf() public view returns (uint256) {
        (uint256 amount, ) = IMasterRefiner(masterRefiner).userInfo(
            0,
            address(this)
        );
        return token.balanceOf(address(this)) + amount;
    }

    /**
     * @notice Deposits tokens into MasterRefinery to earn staking rewards
     */
    function _earn() internal {
        uint256 bal = available();
        if (bal > 0) {
            IMasterRefiner(masterRefiner).enterStaking(bal);
        }
    }

    /**
     * @notice Checks if address is a contract
     * @dev It prevents contract from being targetted
     */
    function _isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
}