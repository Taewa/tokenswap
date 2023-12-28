pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol"; // forge test -vv
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

import "../src/TokenSwapPair.sol";
import "../src/TokenSwapFactory.sol";
import "./TokenContractsForTest.sol";

// useful link: https://www.rareskills.io/post/foundry-testing-solidity
contract TokenSwapPairTest is Test {
    TokenSwapPair pairContract;
    TokenContract token0;
    TokenContract token1;
    address lp = address(3333);
    address swapper = address(4444);
    // address factory = address(9999);
    TokenSwapFactory factory;
    
    string pairName = 'Liquidity Provider Token';
    string pairSymbol = 'LPT';
    
    string token0Name = 'Some Token 0';
    string token0Symbol = 'ST0';
    
    string token1Name = 'Some Token 1';
    string token1Symbol = 'ST1';

    uint decimal = 10 ** 18;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Sync(uint112 reserve0, uint112 reserve1);
    
    // setUp: An optional function invoked before each test case is run.
    function setUp() public {
        // TODO: is there a better way to set up dummy contracts?
        token0 = new TokenContract(token0Name, token0Symbol);
        token1 = new TokenContract(token1Name, token1Symbol);

        factory = new TokenSwapFactory(address(this));

        token0.mint(address(this), 1_000_000 * decimal);
        token1.mint(address(this), 1_000_000 * decimal);
        
        vm.startPrank(address(factory));
        pairContract = new TokenSwapPair(pairName, pairSymbol);
        pairContract.initialize(address(token0), address(token1));
        vm.stopPrank();
    }

    // MINIMUM_LIQUIDITY test
    function testMinimumLiquidity() public {
        uint minLiquidity = pairContract.MINIMUM_LIQUIDITY();

        assertEq(minLiquidity, 10**3, 'it has to be minimum 1000.');
    }

    function testMintWhenThereIsNoTotalSupply() public {
        uint minLiquidity = pairContract.MINIMUM_LIQUIDITY();
        uint token0Amount = 1 * decimal;
        uint token1Amount = 9 * decimal;

        // set up token0,1 for pairContract
        token0.transfer(address(pairContract), token0Amount);
        token1.transfer(address(pairContract), token1Amount);

        // vm.mockCall(
        //     address(factory),
        //     abi.encodeWithSelector(factory.feeTo.selector),
        //     abi.encode(0)
        // );

        vm.expectEmit(address(pairContract));

        // when totalySupply is 0,it transfer MINIMUM_LIQUIDITY to address(0)
        emit Transfer(address(0), address(1), minLiquidity);
        
        // from _mint()
        emit Transfer(address(0), lp, 3 * decimal - minLiquidity);
        
        // from _update()
        emit Sync(uint112(token0Amount), uint112(token1Amount));
        
        emit Mint(address(this), token0Amount, token1Amount);
        pairContract.mint(lp);

        // 'to': 2999999999999999000 + 'address(1)': 1000 = 3000000000000000000
        assertEq(pairContract.totalSupply(), 3 * decimal, 'Math.sqrt(token0Amount * token1Amount)');
        assertEq(pairContract.balanceOf(lp), (3 * decimal) - minLiquidity, 'Share tokens that given to LP');
        assertEq(token0.balanceOf(address(pairContract)), token0Amount, 'token0 that LP provided');
        assertEq(token1.balanceOf(address(pairContract)), token1Amount, 'token1 that LP provided');

        (uint112 _reserve0, uint112 _reserve1,) = pairContract.getReserves();

        assertEq(_reserve0, token0Amount, 'token0 amount that it written in TokenContract');
        assertEq(_reserve1, token1Amount, 'token1 amount that it written in TokenContract');
    }

    function testInitialize() public {
        // create a new contract to test initialize()
        TokenSwapPair tokenSwapPairContractForInitTest = new TokenSwapPair(pairName, pairSymbol);

        // at the beginning no addresses set
        address token0Addr = tokenSwapPairContractForInitTest.token0();
        address token1Addr = tokenSwapPairContractForInitTest.token1();

        assertEq(token0Addr, address(0), 'before initialize() called, token0 address should be address(0)');
        assertEq(token1Addr, address(0), 'before initialize() called, token1 address should be address(0)');

        tokenSwapPairContractForInitTest.initialize(address(token0), address(token1));

        address token0AddrAfterInit = tokenSwapPairContractForInitTest.token0();
        address token1AddrAfterInit = tokenSwapPairContractForInitTest.token1();

        assertEq(token0AddrAfterInit, address(token0), 'should be the same as token0 after initialize');
        assertEq(token1AddrAfterInit, address(token1), 'should be the same as token1 after initialize');
    }
    // https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol#L57
    //       uint amountInWithFee = amountIn.mul(997); // amountIn is the 'swapAmount'
    //       uint numerator = amountInWithFee.mul(reserveOut);
    //       uint denominator = reserveIn.mul(1000).add(amountInWithFee);
    //       amountOut = numerator / denominator;
    function testSwap1() public {
        // test1
        uint256[] memory swapTestCase1 = new uint256[](4);
        swapTestCase1[0] = 1 * decimal;             // swap amount that swapper put into pool. In this case, it's token0's token
        swapTestCase1[1] = 5 * decimal;             // token0 initial amount
        swapTestCase1[2] = 10 * decimal;            // token1 initial amount
        swapTestCase1[3] = 1662497915624478906;     // expected return to swapper. it's actually 1.662497915624478906 (18 decimal point). 

        // set up token0,1 current token situation
        token0.transfer(address(pairContract), swapTestCase1[1]);
        token1.transfer(address(pairContract), swapTestCase1[2]);
        pairContract.mint(lp);

        // swaper sends token to the pool for exchange
        token0.transfer(address(pairContract), swapTestCase1[0]);
        // if no revert, then it's passed
        pairContract.swap(0, swapTestCase1[3], swapper, ""); 

        /**
            This is how expected out amount is calculated via UniswapV2Library
        */
        // uint amountIn = 1 * decimal;
        // uint reserveIn = 1000 * decimal;
        // uint reserveOut = 1000 * decimal;

        // uint amountInWithFee = amountIn * (997);
        // uint numerator = amountInWithFee * reserveOut;
        // uint denominator = reserveIn * 1000 + amountInWithFee;
        // uint amountOut = numerator / denominator;

        // console.log('the result is:');
        // console.log(amountOut);
    }

    function testSwap2() public {
        uint256[] memory swapTestCase2 = new uint256[](4);
        swapTestCase2[0] = 2 * decimal;              // swap amount that swapper put into pool. In this case, it's token0's token
        swapTestCase2[1] = 100 * decimal;            // token0 initial amount
        swapTestCase2[2] = 66 * decimal;             // token1 initial amount
        swapTestCase2[3] = 1290311194776163303;      // expected return to swapper

        // set up token0,1 current token situation
        token0.transfer(address(pairContract), swapTestCase2[1]);
        token1.transfer(address(pairContract), swapTestCase2[2]);
        pairContract.mint(lp);

        // swaper sends token to the pool for exchange
        token0.transfer(address(pairContract), swapTestCase2[0]);
        // if no revert, then it's passed
        pairContract.swap(0, swapTestCase2[3], swapper, ""); 
        
    }

    function testSwap3() public {
        uint256[] memory swapTestCase3 = new uint256[](4);
        swapTestCase3[0] = 4 * decimal;             // swap amount that swapper put into pool. In this case, it's token0's token
        swapTestCase3[1] = 100 * decimal;           // token0 initial amount
        swapTestCase3[2] = 100 * decimal;           // token1 initial amount
        swapTestCase3[3] = 3835057891295149440;     // expected return to swapper.

        // set up token0,1 current token situation
        token0.transfer(address(pairContract), swapTestCase3[1]);
        token1.transfer(address(pairContract), swapTestCase3[2]);
        pairContract.mint(lp);

        // swaper sends token to the pool for exchange
        token0.transfer(address(pairContract), swapTestCase3[0]);
        // if no revert, then it's passed
        pairContract.swap(0, swapTestCase3[3], swapper, ""); 
    }

    function testSwap4() public {
        uint256[] memory swapTestCase4 = new uint256[](4);
        swapTestCase4[0] = 1 * decimal;             // swap amount that swapper put into pool. In this case, it's token0's token
        swapTestCase4[1] = 1000 * decimal;          // token0 initial amount
        swapTestCase4[2] = 1000 * decimal;          // token1 initial amount
        swapTestCase4[3] = 996006981039903216;      // expected return to swapper.

        // set up token0,1 current token situation
        token0.transfer(address(pairContract), swapTestCase4[1]);
        token1.transfer(address(pairContract), swapTestCase4[2]);
        pairContract.mint(lp);

        // swaper sends token to the pool for exchange
        token0.transfer(address(pairContract), swapTestCase4[0]);
        // if no revert, then it's passed
        pairContract.swap(0, swapTestCase4[3], swapper, ""); 
    }

    // unhappy path
    function testSwap5() public {
        uint256[] memory swapTestCase4 = new uint256[](4);
        swapTestCase4[0] = 1 * decimal;             // swap amount that swapper put into pool. In this case, it's token0's token
        swapTestCase4[1] = 1000 * decimal;          // token0 initial amount
        swapTestCase4[2] = 1000 * decimal;          // token1 initial amount
        swapTestCase4[3] = 996006981039903216;      // expected return to swapper.

        // set up token0,1 current token situation
        token0.transfer(address(pairContract), swapTestCase4[1]);
        token1.transfer(address(pairContract), swapTestCase4[2]);
        pairContract.mint(lp);

        // swaper sends token to the pool for exchange
        token0.transfer(address(pairContract), swapTestCase4[0]);
        uint256 wrongOutput = swapTestCase4[3] + 1;
        
        vm.expectRevert('TokenSwap: K');
        pairContract.swap(0, wrongOutput, swapper, ""); 
    }

    // unhappy path
    function testSwap6() public {
        uint256[] memory swapTestCase = new uint256[](4);
        swapTestCase[0] = 1 * decimal;             // swap amount that swapper put into pool. In this case, it's token0's token
        swapTestCase[1] = 1000 * decimal;          // token0 initial amount
        swapTestCase[2] = 1000 * decimal;          // token1 initial amount
        swapTestCase[3] = 996006981039903216;      // expected return to swapper.

        // set up token0,1 current token situation
        token0.transfer(address(pairContract), swapTestCase[1]);
        token1.transfer(address(pairContract), swapTestCase[2]);
        pairContract.mint(lp);

        // swaper sends token to the pool for exchange
        
        token0.transfer(address(pairContract), swapTestCase[0]);
        uint256 wrongOutput = swapTestCase[3] + 1;
        
        vm.expectRevert('TokenSwap: K');
        pairContract.swap(0, wrongOutput, swapper, ""); 
    }

    // unhappy path
    function testSwap7() public {
        vm.expectRevert('TokenSwap: INSUFFICIENT_OUTPUT_AMOUNT');
        pairContract.swap(0, 0, swapper, ""); 
    }

    // unhappy path
    function testSwap8() public {
        uint256[] memory swapTestCase = new uint256[](3);
        swapTestCase[0] = 1 * decimal;           // swap amount that swapper put into pool. In this case, it's token0's token
        swapTestCase[1] = 1 * decimal;           // token0 initial amount
        swapTestCase[2] = 1 * decimal;           // token1 initial amount

        // set up token0,1 current token situation
        token0.transfer(address(pairContract), swapTestCase[1]);
        token1.transfer(address(pairContract), swapTestCase[2]);
        pairContract.mint(lp);

        // swaper sends token to the pool for exchange
        token0.transfer(address(pairContract), swapTestCase[0]);
        
        vm.expectRevert('TokenSwap: INSUFFICIENT_LIQUIDITY');
        pairContract.swap(10 * decimal, 10 * decimal, swapper, ""); 
    }

    // unhappy path
    function testSwap9() public {
        uint256[] memory swapTestCase = new uint256[](4);
        swapTestCase[0] = 1 * decimal;             // swap amount that swapper put into pool. In this case, it's token0's token
        swapTestCase[1] = 1000 * decimal;          // token0 initial amount
        swapTestCase[2] = 1000 * decimal;          // token1 initial amount
        swapTestCase[3] = 996006981039903216;      // expected return to swapper.

        // set up token0,1 current token situation
        token0.transfer(address(pairContract), swapTestCase[1]);
        token1.transfer(address(pairContract), swapTestCase[2]);
        pairContract.mint(lp);

        // swaper sends token to the pool for exchange
        token0.transfer(address(pairContract), swapTestCase[0]);

        vm.expectRevert('TokenSwap: INVALID_TO');
        pairContract.swap(0, swapTestCase[3], address(token0), ""); 
    }

    // unhappy path
    function testSwap10() public {
        uint256[] memory swapTestCase = new uint256[](4);
        swapTestCase[0] = 1 * decimal;             // swap amount that swapper put into pool. In this case, it's token0's token
        swapTestCase[1] = 1000 * decimal;          // token0 initial amount
        swapTestCase[2] = 1000 * decimal;          // token1 initial amount
        swapTestCase[3] = 996006981039903216;      // expected return to swapper.

        // set up token0,1 current token situation
        token0.transfer(address(pairContract), swapTestCase[1]);
        token1.transfer(address(pairContract), swapTestCase[2]);
        pairContract.mint(lp);

        /**
        below code is simulating that trader sent token to the pool.
        Without it, it will occur an error
        */
        // token0.transfer(address(pairContract), swapTestCase[0]);

        vm.expectRevert('TokenSwap: INSUFFICIENT_INPUT_AMOUNT');
        pairContract.swap(0, swapTestCase[3], swapper, ""); 
    }

    // unhappy path
    function testSwap11() public {
        uint256[] memory swapTestCase = new uint256[](4);
        swapTestCase[0] = 1 * decimal;             // swap amount that swapper put into pool. In this case, it's token0's token
        swapTestCase[1] = 1000 * decimal;          // token0 initial amount
        swapTestCase[2] = 1000 * decimal;          // token1 initial amount
        swapTestCase[3] = 996006981039903216;      // expected return to swapper.

        // set up token0,1 current token situation
        token0.transfer(address(pairContract), swapTestCase[1]);
        token1.transfer(address(pairContract), swapTestCase[2]);
        pairContract.mint(lp);

        // swaper sends token to the pool for exchange
        token0.transfer(address(pairContract), swapTestCase[0]);

        vm.expectRevert('TokenSwap: INSUFFICIENT_INPUT_AMOUNT');
        pairContract.swap(0, swapTestCase[3], swapper, ""); 
    }
}