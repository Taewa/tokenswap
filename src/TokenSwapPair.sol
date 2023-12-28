pragma solidity 0.8.20;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/interfaces/IERC20.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';

import './interfaces/ITokenSwapPair.sol';
import './interfaces/ITokenSwapFactory.sol';
import './interfaces/ITokenSwapCallee.sol';

import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";

contract TokenSwapPair is ITokenSwapPair, ERC20 {
  using SafeERC20 for IERC20;

  uint public constant MINIMUM_LIQUIDITY = 10**3;  // it is used when there is no totalSupply (share-token) => lock
  bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

  address public factory;  // the one that create swap contract
  address public token0;   // swap contract needs two different tokens for exchange (EX: USDC <-> Shiba Inu). It's one of them.
  address public token1;

  // reserve0,1 are NOT real token but reflection of token0,1's (below)
  // IERC20(token0 or token1).balanceOf(address(this));
  // Becareful, it might not be up to date (ex: a logic in mint function, amount0,1)
  uint112 private reserve0; // amount of token that THIS CONTRACT holds (NOT token0). Accessible via getReserves
  uint112 private reserve1; // amount of token that THIS CONTRACT holds (NOT token1). Accessible via getReserves
  uint32 private blockTimestampLast;  // Accessible via getReserves
  /**
   it's not internally used. 
   this is for knowing average prices of token0,1 by time passed. By checking 'blockTimestampLast', user can know if anything is updated or not.
   */
  uint public price0CumulativeLast;
  uint public price1CumulativeLast;
  uint public kLast; // reserve0 * reserve1 = k

  uint private unlocked = 1;
  // Below logic prevents reentrancy attack
  modifier lock() {
    require(unlocked == 1, 'TokenSwap: LOCKED');
    unlocked = 0;
    _;
    unlocked = 1; // will be executed after _;
  }

  constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
    factory = msg.sender; // the one that creates this contract is the factory contract.
  }

  function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
    _reserve0 = reserve0;
    _reserve1 = reserve1;
    _blockTimestampLast = blockTimestampLast;
  }


  // It will be called once by the factory during deployment and set token contracts
  function initialize(address _token0, address _token1) external {
    require(msg.sender == factory, 'TokenSwap: FORBIDDEN'); // only the onw that created this contract can run this function
    token0 = _token0;
    token1 = _token1;
  }

  function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
    /**
      balance0 is uint which means it can over uint112
      then there is this code reserve0 = uint112(balance0); reserve0 is uint112
      so if balance0 is more then uint112, then uint112(balance0) causes a serious problem
      if balance0 is (type(uint112).max + 1) then reserve0 will be 1 instead of 4294967291
    */
    require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, 'TokenSwap: OVERFLOW');
    /**
    That essentially clamps the value to 32 bits. Such that if timestamp ever becomes greater than type(uint32).max, 
    it will restart from zero. That will happen sometime in 2100s. The idea is the unchecked subtraction in the following line will 
    continue working properly even when timestamp overflows.
    */
    uint32 blockTimestamp = uint32(block.timestamp % 2**32);
    uint32 timeElapsed = blockTimestamp - blockTimestampLast; // to check how long time is passed

    if(timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
      /**
      purpose of 'encode':
      uint224 constant Q112 = 2**112; // scailing factor for decimal point
      function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112; // never overflow: make decimal point.
      }
      
      it makes decimal point by adding 2**112. Simply put, if y = 5, z will be 5.0000000...
      */
      /**
      purpose of 'uqdiv'
      function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
      }
      By doing so, result (z) can have decimal (ex: x=5 y=2 => 2.5).
      More precise example:
      x=5
      y=2

      (in encode)
      x = uint224(x) * (2**112)

      (in uqdiv)
      z = x / uint224(y)
      z / (2**112) will result 2.5
      */ 
      //'using' keyword makes it chain (ex: encode(_reserve1).uqdiv(_reserve0))
      //https://www.rareskills.io/post/twap-uniswap-v2
      // TWAP (time-weighted average price). It's a pricing algorithm used to calculate the average price of an asset over a set period.
      // a TWAP weights price by how long the price stays at a certain level.
      /**
        ex1) Over the last day, the price of an asset was $10 for the first 12 hours and $11 for the second 12 hours. 
        The average price is the same as the time weighted average price: $10.5.
        ex2) Over the last day, the price of an asset was $10 for the first 23 hours and $11 for the most recent one. 
        The expected average price should be closer to $10 than $11, but it will still be in between those values. Specifically, 
        it will be ($10 * 23 + $11 * 1) / 24 = $10.0417
        ex3) Over the last day, the price of an asset was $10 for the first hour, and $11 for the most recent 23 hours. 
        We expect the TWAP to be closer to $11 than 10. Specifically, it will be ($10 * 1 + $11 * 23) / 24 = $10.9583
      */
      // reserve0,1 are the ratio of asset weighted by time (timeElapsed)
      // why it's added up (+=)? Where do we use it? => not internally used. this is for knowing average prices of token0,1 by time passed. By checking 'blockTimestampLast', user can know if anything is updated or not.
      // 'using' decorator allows chaining function ( ex: a(_x).b(_y) )
      // price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
      // price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
      UD60x18 _reserve0Ud = ud(_reserve0);
      UD60x18 _reserve1Ud = ud(_reserve1);
      price0CumulativeLast += _reserve1Ud.div(_reserve0Ud).unwrap() * timeElapsed;
      price1CumulativeLast += _reserve0Ud.div(_reserve1Ud).unwrap() * timeElapsed;
    }

    reserve0 = uint112(balance0); // balance0 is from IERC20(token0).balanceOf(address(this))
    reserve1 = uint112(balance1); // balance1 is from IERC20(token1).balanceOf(address(this))
    blockTimestampLast = blockTimestamp;

    emit Sync(reserve0, reserve1);
  }

  // Only called via mint and burn which is infrequent. NOT by swap
  function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns(bool feeOn) {
    address feeTo = ITokenSwapFactory(factory).feeTo();
    feeOn = feeTo != address(0);
    uint _kLast = kLast;  // gas savings because it has to access storage variable and it's better caching in local variable.

    if(feeOn) {
      if(_kLast != 0) {
        // TODO: do it later
        // TODO: should update below since SafeMath is not needed since 0.8.x
        uint rootK = Math.sqrt(_reserve0 * _reserve1); // it's opposite to x * y = k
        uint rootKLast = Math.sqrt(_kLast);
        
        if (rootK > rootKLast) {  // true means there are more tokens added by LP
          // TODO: I don't understand below logic
          uint numerator = totalSupply() * uint(rootK - rootKLast);
          uint denominator = rootK * 5 + rootKLast;
          uint liquidity = numerator / denominator;
          if (liquidity > 0) _mint(feeTo, liquidity); // TODO: sending fee to the fee-contract?
        }
      }
    } else if (_kLast != 0) {
      kLast = 0;
    }
  }
  
  // this low-level function should be called from a contract which performs important safety checks
  // mint fn creates share-token for LP (Liquidity Provider) who sent token0,1 to the pool
  function mint(address to) external lock returns(uint liquidity) {
    (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
    /**
    The flow of mint() usage:
    1. LP approves tokens for Router to use
    2. then calls router
    3. The Router then does a transferFrom to the pair contract and call mint
    4. So when mint() is called, there is already tokens in each token0,1 that LP sent
    */
    uint balance0 = IERC20(token0).balanceOf(address(this));  // token that is stored in token0 contract. NOT this pair contract.
    uint balance1 = IERC20(token1).balanceOf(address(this));
    /**
      Q: shouldn't I check balance0 > reserve0? -> otherwise the occurs error in case it becomes less than 0?
      A: If the Pair contract code is bug free (which it is), and the tokens in it behaving correctly, 
      then balances can only be greater or equal to the reserves, because there isn't anywhere in the Pair 
      contract where tokens are transferred out of the contract without updating the reserves. But yeah, 
      if assumptions do not hold, that subtraction could underflow.
    */
    uint amount0 = balance0 - reserve0;
    uint amount1 = balance1 - reserve1;

    bool feeOn = _mintFee(_reserve0, _reserve1);
    uint _totalSupply = totalSupply(); // gas savings, must be defined here since totalSupply can update in _mintFee
    if(_totalSupply == 0) {
      /**
        Q: I guess it can be 2 secanarios either no liquidity providing or LP burned tokens?
        A: No, because MINIMUM_LIQUIDITY amount of liquidity is locked forever and cannot be burned.
      */
      // TODO: I don't understand below logic
      /**
        Q: Why subtracts MINIMUM_LIQUIDITY?
        A: It technically takes that amount from the initial liquidity provider, but it's a miniscule amount, 
        so doesn't harm the LP.
      */
      liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
      /**
        Q: why mints to address(0) (I meant some address for MINIMUM_LIQUIDITY)
        A: To burn it. See inflation attack. https://mixbytes.io/blog/overview-of-the-inflation-attack
      */
      _mint(address(1), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens

    } else {
      // calculating share-token (i.e. liquidity). 

      // _reserve0,1 tokens that are stored in this contract. At this point in mint fn, _reserve0,1 are not up to date compared to balance0,1 because 
      // _reserve0,1 don't have yet what LP sent via transaction. It will be updated via _update() below
      /**
        I think it tries to get ratio of amount0,1 from reserve0,1 in scale of totalSupply
        Then take smaller one between amount0,1 and assign to 'liquidity'
      */
      liquidity = Math.min(amount0 * _totalSupply / _reserve0, amount1 * _totalSupply / _reserve1);
      // TODO: the above is :
      // (LP's added token0 * entire total share-tokens) / amount of token0 before LP adds
    }

    require(liquidity > 0, 'TokenSwap: INSUFFICIENT_LIQUIDITY_MINTED');
    _mint(to, liquidity); // create share-token (or another name as LP token)

    _update(balance0, balance1, _reserve0, _reserve1);

    if(feeOn) kLast = uint(reserve0) * uint(reserve1); // x * y = k
    emit Mint(msg.sender, amount0, amount1);
  }

  // this low-level function should be called from a contract which performs important safety checks
  // burn fn delete share-token which is sent from LP. Then LP receives token0,1 
  function burn(address to) external lock returns (uint amount0, uint amount1) {
    (uint112 _reserve0, uint112 _reserve1,) = getReserves();
    address _token0 = token0;
    address _token1 = token1;
    uint balance0 = IERC20(_token0).balanceOf(address(this)); //TODO: why it's gas savings?
    uint balance1 = IERC20(_token1).balanceOf(address(this)); //TODO: why it's gas savings?
    uint liquidity = balanceOf(address(this));  // TODO: at this point, share-token is already sent from a LP to this contract

    bool feeOn = _mintFee(_reserve0, _reserve1);
    uint _totalSupply = totalSupply();

    // TODO: need confirmation => amount0,1 are the ratio of liquidity of totalSupply (share-token)?
    amount0 = (liquidity * balance0) / _totalSupply;
    amount1 = (liquidity * balance1) / _totalSupply;

    require(amount0 > 0 && amount1 > 0, 'TokenSwap: INSUFFICIENT_LIQUIDITY_BURNED');

    // burn (remove) share-token because LP wants to take back tokens from token0,1
    _burn(address(this), liquidity);

    // send token0,1 to LP
    // TODO: 'to' is LP?
    IERC20(token0).safeTransfer(to, amount0);
    IERC20(token1).safeTransfer(to, amount1);

    // balance0,1 are now reduced since amount0,1 are subtracked  
    balance0 = IERC20(_token0).balanceOf(address(this));
    balance1 = IERC20(_token1).balanceOf(address(this));

    // update to sync with reserve0,1
    _update(balance0, balance1, _reserve0, _reserve1);

    if(feeOn) kLast = uint(reserve0) * uint(reserve1);  // x * y = k
    emit Burn(msg.sender, amount0, amount1, to);
  }

  // this low-level function should be called from a contract which performs important safety checks
  // amount0Out,1 are the token that trader will receive
  // amount0In,1 are the token that trader sent to the pool
  function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
    require(amount0Out > 0 || amount1Out > 0, 'TokenSwap: INSUFFICIENT_OUTPUT_AMOUNT');
    (uint112 _reserve0, uint112 _reserve1,) = getReserves();
    require(amount0Out < _reserve0 && amount1Out < _reserve1, 'TokenSwap: INSUFFICIENT_LIQUIDITY');

    uint balance0;
    uint balance1;

    /**
      EVM allows accessing the top 16 stack values through opcodes like DUP[1-16]. 
      So if you have written a function that has lots of local variables that might 
      take away all those slots and Solidity compiler doesn't know how to handle it. 
      You can use scoping to workaround that.
    */
    { // scope for _token{0,1}, avoids stack too deep errors
    address _token0 = token0;
    address _token1 = token1;

    //TODO: 'to' should be a trader?
    require(to != _token0 && to != _token1, 'TokenSwap: INVALID_TO');
    //sending token to trader
    if(amount0Out > 0) IERC20(token0).safeTransfer(to, amount0Out); // TODO: why '_safeTransfer' instead of IERC20(_token0).transfer(...) ?
    if(amount1Out > 0) IERC20(token1).safeTransfer(to, amount1Out);
    // usage of tokenSwapCall() would be a contract that does flashloaning from the Pair contract.
    if(data.length > 0) ITokenSwapCallee(to).tokenSwapCall(msg.sender, amount0Out, amount1Out, data);

    balance0 = IERC20(_token0).balanceOf(address(this));
    balance1 = IERC20(_token1).balanceOf(address(this));
    }

    /**
    token that is sent from a trader to the pool.
    calculate how much trader sent.
    trader sends one type of tokens (ex: token0) and receive other token (ex: token1)
    so, one of them (amount0In and amount1In) is going to be 0 because trader didn't send
    */
    uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
    uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;

    // One of then must be greater than 0 because trader must sent at least one token to swap
    require(amount0In > 0 || amount1In > 0, 'TokenSwap: INSUFFICIENT_INPUT_AMOUNT');
    {
    /**
    multiplying by 1000 because solidity cannot implement * 0.03. (3 stands for 0.3% of token swap fee)
    */
    uint balance0Adjusted = (balance0 * 1000) - (amount0In * 3);
    uint balance1Adjusted = (balance1 * 1000) - (amount1In * 3);
    
    /** 
      It is derived from core Uniswap invariant x*y=k. Basically 
      this x_new * y_new >= x_old * y_old but with fees also taken into consideration.
    */
    require(balance0Adjusted * balance1Adjusted >= uint(_reserve0) * uint(_reserve1) * 1000**2, 'TokenSwap: K');  // whenever swap is called, K should be increased
    }

    _update(balance0, balance1, _reserve0, _reserve1);
    emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
  }

  /**
    It just allows you to withdraw tokens not yet incorporated to reserves.
    An example is refletive tokens (which send X% fee to holders on each tx). 
    Since the Pair contract would be a holder, its balance would be increasing, 
    but that would not be reflected to the reserves. So it allows someone to just withdraw those extra tokens.
  */
  function skim(address to) external lock {
    address _token0 = token0;
    address _token1 = token1;

    IERC20(token0).safeTransfer(to, IERC20(_token0).balanceOf(address(this)) - reserve0);
    IERC20(token1).safeTransfer(to, IERC20(_token1).balanceOf(address(this)) - reserve1);
  }

  /**
  Sync between token0 and token1 contracts with this contract's reserve0, reserve1
  reserve0, reserve1 are reflection of token0 and token1 contract's tokens
  */
  function sync() external lock {
    _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
  }
}
