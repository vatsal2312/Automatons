// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ERC20.sol";
import "./Ownable.sol";
import "./ReentrancyGuard.sol";

contract Token is ERC20, Ownable, ReentrancyGuard {
    /**
     * @dev TOTAL_SUPPLY
     * Total supply of the token, expressed in wei.
     */
    uint256 private constant TOTAL_SUPPLY = 1000000 * (10 ** 18); // 1,000,000 tokens

    /**
     * @dev VESTING_DURATION
     * Total vesting duration in seconds.
     */
    uint256 private constant VESTING_DURATION = 24 * 30 days; // 24 months

    /**
     * @dev VESTING_INTERVAL
     * Vesting interval in seconds.
     */
    uint256 private constant VESTING_INTERVAL = VESTING_DURATION / 4; // 6 months

    /**
     * @dev VESTING_AMOUNT
     * Percentage of the total supply, used for vesting.
     */
    uint256 private constant VESTING_AMOUNT = (TOTAL_SUPPLY * 10) / 100; // 10%

    /**
     * @dev vestingCliff
     * Timestamp representing the cliff at which vested tokens are released.
     */
    uint256 private vestingCliff;

    /**
     * @dev developer
     * Address of the developer wallet.
     */
    address private developer = 0x0986D2fbc6B4FA8D738095BCf150De99A9FB62b5;

    /**
     * @dev vester
     * Vester address.
     */
    address private vester = 0x97c297dfcd2e1cce88398d194215D2d0e709CC92;

    /**
     * @dev taxPercent
     * Tax percentage for buy/sell/transfer.
     */
    uint256 private taxPercent = 150; // 1.5%

    /**
     * @dev developerTaxPercent
     * Tax share percentage designated for the developer.
     */
    uint256 private developerTaxPercent = 5000; // 50% of taxAmount

    /**
     * @dev reflectionsTaxPercent
     * Tax share percentage designated for reflections.
     */
    uint256 private reflectionsTaxPercent = 5000; // 50% of taxAmount

    /**
     * @dev _reflectionBalances
     * Total reflection balances in wei.
     */
    uint256 private _reflectionBalances;

    /**
     * @dev _lastReflectionTime
     * Timestamp of the last reflection time.
     */
    uint256 private _lastReflectionTime;

    /**
     * @dev _released
     * Total amount of released tokens in wei.
     */
    uint256 private _released;

    /**
     * @dev _totalSupply
     * Total supply of the token in wei.
     */
    uint256 internal _totalSupply;

    /**
     * @dev _balances
     * Mapping to store balances of token holders in wei.
     */
    mapping(address => uint256) private _balances;

     /**
     * @dev restrictedAddresses
     * Mapping to store tax excluded addresses.
     */
    mapping(address => bool) private excludedAddresses;

    /**
     * @dev _reflectionClaimTimes
     * Mapping to store reflection claim times for token holders.
     */
    mapping(address => uint256) private _reflectionClaimTimes;

    /**
     * @dev TokensReleased
     * Event emitted upon releasing tokens to a beneficiary.
     */
    event TokensReleased(address indexed beneficiary, uint256 amount);

    /**
     * @dev DevWalletSet
     * Event emitted upon updating the dev wallet.
     */
    event DevWalletSet(address indexed newDevAddress, uint256 timestamp);

    /**
     * @dev constructor
     * Constructor function to initialize the token with initial balances and settings.
     */
    constructor() ERC20("Automatons AI", "AAI") Ownable(_msgSender()) {
        // Holdback tokens
        _addBalance(_msgSender(), TOTAL_SUPPLY - VESTING_AMOUNT);
        _addBalance(address(this), VESTING_AMOUNT);
        _totalSupply += TOTAL_SUPPLY;
        emit Transfer(address(0), _msgSender(), TOTAL_SUPPLY - VESTING_AMOUNT);
        emit Transfer(address(0), address(this), VESTING_AMOUNT);
        _lastReflectionTime = block.timestamp;
        vestingCliff = block.timestamp;

        excludedAddresses[_msgSender()] = true;
        excludedAddresses[developer] = true;
        excludedAddresses[vester] = true;
    }

    /**
     * @dev Fallback function to handle Ether transfers and function calls that don't match any other function signature.
     * This function is triggered when a transaction is sent to the contract with no data or when it's sent data that doesn't match any function signature.
     * It is marked as payable, meaning it can receive Ether.
     * The fallback function is typically used to handle unexpected or unspecified interactions with the contract.
     * It can be used to receive Ether or perform other actions based on the contract's logic.
     */
    fallback() external payable {}

    /**
     * @dev Fallback function to receive Ether.
     * This function is called when the contract receives Ether without a specified function to call.
     * It is marked as external and payable, meaning it can be called externally and can receive Ether.
     * It allows the contract to accept Ether sent to it directly, without a specific function call.
     */
    receive() external payable {}

    /**
     * @dev totalSupply
     * Function to retrieve the total supply of the token.
     */
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev Check if an address corresponds to a contract by inspecting its bytecode size.
     * @param _addr The address to be checked.
     * @return A boolean indicating whether the address is a contract (`true`) or not (`false`).
     */
    function isContract(address _addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }

    /**
     * @dev setDevWallet
     * Function to set the developer wallet address.
     * @param newDevAddress The new address designated as the developer wallet.
     */
    function setDevWallet(address newDevAddress) external onlyOwner {
        require(!isContract(newDevAddress), "Address is a contract");
        require(newDevAddress != address(0) && newDevAddress != address(0x000000000000000000000000000000000000dEaD), "Invalid address");
        developer = newDevAddress;
        emit DevWalletSet(newDevAddress, block.timestamp);
    }

    /**
     * @dev _update
     * Internal function which overrides default function to include checks and tax reflection.
     * @param sender The address initiating the transfer.
     * @param recipient The address receiving the transfer.
     * @param amount The amount being transferred.
     */
    function _update(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        claimReflections(sender);
        claimReflections(recipient);
        _reflectTaxes(sender, recipient, amount);
    }

    /**
     * @dev _isIncluded
     * Internal function to check if an account is not excluded from certain features.
     * @param account The address to check.
     * @return A boolean indicating whether the account is not excluded.
     */
    function _isIncluded(address account) internal view returns (bool) {
        return !excludedAddresses[account];
    }

    /**
     * @dev _reflectTaxes
     * Internal function to calculate and distribute taxes on transfers.
     * @param sender The address initiating the transfer.
     * @param recipient The address receiving the transfer.
     * @param amount The amount being transferred.
     */
    function _reflectTaxes(
        address sender,
        address recipient,
        uint256 amount
    ) private {
        if(_isIncluded(sender) && _isIncluded(recipient)) {
            uint256 taxAmount = (amount * taxPercent) / 10000;
            uint256 developerTax = (taxAmount * developerTaxPercent) / 10000;
            uint256 reflectionsTax = (taxAmount * reflectionsTaxPercent) / 10000;

            _rawTransfer(sender, recipient, amount - taxAmount);
            _rawTransfer(sender, address(this), reflectionsTax);
            _rawTransfer(sender, developer, developerTax);

            _reflectionBalances += reflectionsTax;
            _lastReflectionTime = block.timestamp;
        } else {
            _rawTransfer(sender, recipient, amount);
        }
    }

    /**
     * @dev _rawTransfer
     * Internal function to perform a transfer without tax deduction.
     * @param sender The address initiating the transfer.
     * @param recipient The address receiving the transfer.
     * @param amount The amount being transferred.
     */
    function _rawTransfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        uint256 senderBalance = balanceOf(sender);
        require(senderBalance >= amount, "Transfer amount exceeds balance");
        unchecked {
            _subtractBalance(sender, amount);
        }
        _addBalance(recipient, amount);

        emit Transfer(sender, recipient, amount);
    }

    /**
     * @dev _addBalance
     * Internal function to increase the balance of an account.
     * @param account The address whose balance is being increased.
     * @param amount The amount to increase the balance by.
     */
    function _addBalance(address account, uint256 amount) internal {
        _balances[account] = _balances[account] + amount;
    }

    /**
     * @dev _subtractBalance
     * Internal function to decrease the balance of an account.
     * @param account The address whose balance is being decreased.
     * @param amount The amount to decrease the balance by.
     */
    function _subtractBalance(address account, uint256 amount) internal {
        _balances[account] = _balances[account] - amount;
    }

    /**
     * @dev claimReflections
     * Function for token holders to claim reflections.
     * @param recipient The address whose reflection is being claimed.
     * Reflections are distributed based on the time elapsed since the last purchase/claim.
     */
    function claimReflections(address recipient) public nonReentrant {
        uint256 reflectionAmount = _calculateReflections(recipient);
       
        _reflectionBalances -= reflectionAmount;
        _reflectionClaimTimes[recipient] = block.timestamp;

        _rawTransfer(address(this), recipient, reflectionAmount);
    }

    /**
     * @dev _calculateReflections
     * Internal function to calculate the reflections available for a token holder.
     * @param account The address of the token holder.
     * @return reflectionAmount The amount of reflections available for the token holder.
     */
    function _calculateReflections(
        address account
    ) public view returns (uint256) {
        uint256 claimTime = _reflectionClaimTimes[account];
        if (claimTime == 0) {
            claimTime = _lastReflectionTime;
        }

        uint256 elapsedTime = block.timestamp - claimTime;
        uint256 rate = _getReflectionRate(elapsedTime);
        return (rate * balanceOf(account) * _reflectionBalances) / (totalSupply() * 100);
    }

    /**
     * @dev _getReflectionRate
     * Internal function to determine the reflection rate based on the elapsed time since last claim.
     * @param elapsedTime The time elapsed since last claim.
     * @return rate The reflection rate.
     */
    function _getReflectionRate(
        uint256 elapsedTime
    ) private pure returns (uint256) {
        if (elapsedTime >= 365 days) {
            return 20;
        } else if (elapsedTime >= 180 days) {
            return 16;
        } else if (elapsedTime >= 90 days) {
            return 12;
        } else if (elapsedTime >= 30 days) {
            return 8;
        } else if (elapsedTime >= 7 days) {
            return 4;
        } else if (elapsedTime >= 1 days) {
            return 2;
        } else {
            return 0;
        }
    }

    /**
     * @dev reflectionBalance
     * Function to retrieve the total reflection balances available.
     * @return _reflectionBalances The total reflection balances.
     */
    function reflectionBalance() external view returns (uint256) {
        return _reflectionBalances;
    }

    /**
     * @dev balanceOf
     * Function to retrieve the balance of a specified account.
     * @param account The address of the account.
     * @return balance The balance of the specified account.
     */
    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev release
     * Function to release vested tokens to the vester.
     * Only the vester can call this function.
     */
    function release() public nonReentrant {
        require(_msgSender() == vester, "Not vester");
        uint256 unreleased = _releasableAmount();
        require(unreleased > 0, "No tokens are due");

        _released += unreleased;
        _rawTransfer(address(this), _msgSender(), unreleased);
        emit TokensReleased(_msgSender(), unreleased);
    }

    /**
     * @dev _releasableAmount
     * Internal function to calculate the amount of vested tokens available for release.
     * @return unreleased The amount of vested tokens available for release.
     */
    function _releasableAmount() private view returns (uint256) {
        return _vestedAmount() - _released;
    }

    /**
     * @dev _vestedAmount
     * Internal function to calculate the amount of vested tokens based on vesting schedule.
     * @return vestedAmount The amount of vested tokens.
     */
    function _vestedAmount() private view returns (uint256) {
        uint256 amountPerInterval = VESTING_AMOUNT / 4; // 4 intervals
        uint256 elapsedTime = block.timestamp - vestingCliff;
        if (elapsedTime >= VESTING_DURATION) {
            return VESTING_AMOUNT;
        } else if (elapsedTime >= 3 * VESTING_INTERVAL) {
            return 3 * amountPerInterval;
        } else if (elapsedTime >= 2 * VESTING_INTERVAL) {
            return 2 * amountPerInterval;
        } else if (elapsedTime >= VESTING_INTERVAL) {
            return amountPerInterval;
        } else {
            return 0;
        }
    }
}
