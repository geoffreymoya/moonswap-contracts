pragma solidity >=0.5.0;

interface IRefineryCallee {
    function RefineryCall(address sender, uint amount0, uint amount1, bytes calldata data) external;
}