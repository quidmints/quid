// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.4 <0.9.0;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

contract mock is ERC20 {
    address internal rover;
    modifier onlyVogue {
        require(msg.sender == address(rover), "403"); _;
    }
    constructor(address _rover, uint8 _decimals) 
        ERC20("mock", "mock", _decimals) {
        rover = _rover; // Vogue range...
    }
    function mint(uint amount) onlyVogue external {
        _mint(msg.sender, amount);
    }
    function burn(uint amount) onlyVogue external {
        _burn(msg.sender, amount);   
    }
}
