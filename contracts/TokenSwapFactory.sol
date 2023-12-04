pragma solidity 0.8.20;

import './interfaces/ITokenSwapFactory.sol';
import './interfaces/ITokenSwapPair.sol';
import './TokenSwapPair.sol';

contract TokenSwapFactory is ITokenSwapFactory {
    address public feeTo;
    address public feeToSetter;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    constructor(address _feeToSetter) {
        feeToSetter = _feeToSetter;
    }

    function getPairsLength() external view returns(uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns(address pair) {
        require(tokenA != tokenB, 'TokenSwap: No IDENTICAL_ADDRESSES between A and B');
        
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        require(token0 != address(0), 'TokenSwap: token address should not be ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'TokenSwap: pair already existss. PAIR_EXISTS'); // single check is sufficient

        bytes memory bytecode = type(TokenSwapPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));

        assembly {
            /**
                create2(value, offset, size, salt)
                value = amount of wei
                offset = memory start pointer
                size = size of code
                salt = salt
            */
            pair := create2(
                0,                   // sends 0 wei (up to you)
                add(bytecode, 0x20), // actual code starts after skipping the first 32bytes (0x20)
                mload(bytecode),     // load size of code including the first 32bytes TODO: how it includes the first of 32 bytes
                salt
            )

            /**
                There is a way to get an address of contract that is created by
                create2

                bytes32 hash = keccak256(
                bytes1(0xff),
                address(this),
                _salt   // whatever uint
                keccak256(bytecode) // ex:abi.encodePacked(abi.encodePacked(type(TokenSwapPair).creationCode, adi.encode(any params for constructor));)
            )

                address contractAddress = address(uint160(uint256(hash)))   // <- address
            */
            
        }

        // init newly created TokenPair contract
        ITokenSwapPair(pair).initialize(token0, token1);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'TokenSwap: FORBIDDEN');

        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'TokenSwap: FORBIDDEN');

        feeToSetter = _feeToSetter;
    }
}