pragma solidity 0.8.20;

interface ITokenSwapCallee {
    function tokenSwapCall(address sender, uint amount0, uint amount1, bytes calldata data) external;
}