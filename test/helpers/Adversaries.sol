// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HandleVault} from "../../src/HandleVault.sol";

contract HostileToken is ERC20 {
    bool public failTransfer;
    bool public failTransferFrom;
    bool public chargeFee;
    address public callbackTarget;
    bytes public callbackData;
    bool public attempted;
    bool public reentered;
    bytes public callbackResult;

    constructor() ERC20("Hostile test token", "HOSTILE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(bool transferFails, bool transferFromFails, bool fee) external {
        failTransfer = transferFails;
        failTransferFrom = transferFromFails;
        chargeFee = fee;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
        attempted = false;
        reentered = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfer) return false;
        bool result = super.transfer(to, amount);
        _callback();
        return result;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failTransferFrom) return false;
        bool result = super.transferFrom(from, to, amount);
        _callback();
        return result;
    }

    function _callback() internal {
        if (callbackTarget != address(0) && !attempted) {
            attempted = true;
            (reentered, callbackResult) = callbackTarget.call(callbackData);
        }
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (chargeFee && from != address(0) && to != address(0) && amount > 1) {
            super._update(from, address(0), 1);
            super._update(from, to, amount - 1);
        } else {
            super._update(from, to, amount);
        }
    }
}

contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract NativeReceiver {
    HandleVault public vault;
    bytes public payload;
    bool public reject;
    bool public attempted;
    bool public reentered;
    bytes public result;
    uint256 public observedOpenNative;

    function configure(HandleVault target, bytes calldata data, bool shouldReject) external {
        vault = target;
        payload = data;
        reject = shouldReject;
        attempted = false;
    }

    function depositNative(bytes32 recipientId) external payable returns (uint256) {
        return vault.depositNativeFor{value: msg.value}(recipientId);
    }

    receive() external payable {
        require(!reject, "receiver rejects");
        observedOpenNative = vault.totalOpen(address(0));
        if (payload.length != 0 && !attempted) {
            attempted = true;
            (reentered, result) = address(vault).call(payload);
        }
    }
}
