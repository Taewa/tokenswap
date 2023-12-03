pragma solidity 0.8.20;

interface ITokenSwapFactory {
    function feeTo() external view returns (address);
}