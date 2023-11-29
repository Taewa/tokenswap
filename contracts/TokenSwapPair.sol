pragma solidity 0.8.19;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/interfaces/IERC20.sol';

import './interfaces/ITokenSwapPair.sol';
import './interfaces/ITokenSwapFactory.sol';
import './interfaces/ITokenSwapCallee.sol';

contract TokenSwap is ITokenSwapPair, ERC20 {
  //TODO: why not hard code MINIMUM_LIQUIDITY as 1000 ?
  uint public constant MINIMUM_LIQUIDITY = 10**3;  // it is used when there is no totalSupply (share-token) 
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

  uint public price0CumululativeLast; //TODO: not sure what is does
  uint public price1CumululativeLast; //TODO: not sure what is does
  uint32 private kLast; // reserve0 * reserve1 = k

  uint private unlocked = 1;
  // Below logic prevents reentrancy attack
  modifier lock() {
    require(unlocked == 1, 'TokenSwap: LOCKED');
    unlocked = 0;
    _;
    unlocked = 1; // will be executed after _;
  }

  function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
    _reserve0 = reserve0;
    _reserve1 = reserve1;
    _blockTimestampLast = blockTimestampLast;
  }

  event Mint(address indexed sender, uint amount0, uint amount1);
  event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
  event Swap(
    address indexed sender,
    uint amount0In,
    uint amount1In,
    uint amount0Out,
    uint amount1Out,
    address indexed to
  );
  event Sync(uint112 reserve0, uint112 reserve1);

  constructor() public {
    factory = msg.sender; // the one that creates this contract is the factory contract.
  }

  // It will be called once by the factory during deployment and set token contracts
  function initialize(address _token0, address _token1) external {
    require(msg.sender == factory, "TokenSwap: FORBIDDEN"); // only the onw that created this contract can run this function
    token0 = _token0;
    token1 = _token1;
  }

  function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
    // require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'TokenSwap: OVERFLOW'); //TODO: since Solidity 0.8+ has build in SafeMath, does it need?
    uint32 blockTimestamp = uint32(block.timestamp % 2**32);  // TODO: why is does that?
    uint32 timeElapsed = blockTimestamp - blockTimestampLast; // to check how long time is passed

    if(timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
      //TODO: encode는 절대 최대수를 못넘게 하는 역할인듯? 
      //TODO: uqdiv는 왜 arg를 하나만 받지?
      //TODO: understand this: https://www.rareskills.io/post/twap-uniswap-v2
      price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
      price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
    }

    reserve0 = uint112(balance0); // balance0 is from IERC20(token0).balanceOf(address(this))
    reserve1 = uint112(balance1); // balance1 is from IERC20(token1).balanceOf(address(this))
    blockTimestampLast = blockTimestamp;

    emit Sync(reserve0, reserve1);
  }

  function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns(bool feeOn) {
    address feeTo = ITokenSwapFactory(factory).feeTo();
    feeOn = feeTo != address(0);
    uint _kLast = kLast;  // TODO: why it's gas savings?

    if(feeOn) {
      if(_kLast != 0) {
        // TODO: should update below since SafeMath is not needed since 0.8.x
        uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1)); // it's opposite to x * y = k
        uint rootKLast = Math.sqrt(_kLast);
        
        if (rootK > rootKLast) {  // TODO: I guess it checkes if current K (new values of reserve0 and 1) is higher than last K which means more funds in this contract
          // TODO: I don't understand below logic
          uint numerator = totalSupply.mul(rootK.sub(rootKLast));
          uint denominator = rootK.mul(5).add(rootKLast);
          uint liquidity = numerator / denominator;
          if (liquidity > 0) _mint(feeTo, liquidity);
        }
      }
    } else if (_kLast != 0) {
      kLast = 0;
    }
  }
  
  // this low-level function should be called from a contract which performs important safety checks
  // mint fn creates share-token for LP (Liquidity Provider) who sent token0,1 to the pool
  function mint(address to) external lock returns(uint liquidity) {
    (uint112 _reserve0, uint112 _reserve1) = getReserves();   //TODO: why gas savings?
    // balance0,1 are the most up to date number including the LP sent?
    // TODO: When a LP sends tokens0 and 1, they go directly to token0,1 contract?
    uint balance0 = IERC20(token0).balanceOf(address(this));  // token that is stored in token0 contract. NOT this pair contract.
    uint balance1 = IERC20(token1).balanceOf(address(this));
    // TODO: balance0 - reserve0 can mean currentValue - pastValue? it's because token0,1 are up to date?
    uint amount0 = balance0 - reserve0; //TODO: shouldn't I check balance0 > reserve0? => otherwise the occurs error in case it becomes less than 0?
    uint amount1 = balance1 - reserve1; //TODO: shouldn't I check balance1 > reserve1? => otherwise the occurs error in case it becomes less than 0?

    bool feeOn = _mintFee(_reserve0, _reserve1);
    //TODO: total supply is the total number of share-token, right?
    uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
    if(_totalSupply == 0) {
      // TODO: I guess it can be 2 secanarios either no liquidity providing or LP burned tokens?
      // TODO: I don't understand below logic
      liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
      _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens

    } else {
      // calculating share-token (i.e. liquidity). 

      // TODO: amount0,1 are multiplied by totalSupply then devided by reserve0,1. Why?
      // _reserve0,1 tokens that are stored in this contract. At this point in mint fn, _reserve0,1 are not up to date compared to balance0,1 because 
      // _reserve0,1 don't have yet what LP sent via transaction. It will be updated via _update()
      liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
      // TODO: the above is :
      // (LP's added token0 * entire total share-tokens) / amount of token0 before LP adds
    }

    require(liquidity > 0, 'TokenSwap: INSUFFICIENT_LIQUIDITY_MINTED');
    _mint(to, liquidity); // create share-token (or another name as LP token)

    // TODO: need confirmation => what _update does is updating
    // reserve0,1 and reserve0,1 are the reflection of token0,1's balanceOf(address(this)), correct?
    // if true, the reason why it does is for gas saving? => it's also design. => what's benefit?
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
    uint _totalSupply = totalSupply;

    // TODO: need confirmation => amount0,1 are the ratio of liquidity of totalSupply (share-token)?
    amount0 = (liquidity * balance0) / _totalSupply;
    amount1 = (liquidity * balance1) / _totalSupply;

    require(amount0 > 0 && amount1 > 0, 'TokenSwap: INSUFFICIENT_LIQUIDITY_BURNED');

    // burn (remove) share-token because LP wants to take back tokens from token0,1
    _burn(address(this), liquidity);

    // send token0,1 to LP
    // TODO: 'to' is LP?
    _safeTransfer(_token0, to, amount0);
    _safeTransfer(_token1, to, amount1);

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

    { //TODO: I don't understand => scope for _token{0,1}, avoids stack too deep errors
    address _token0 = token0;
    address _token1 = token1;

    //TODO: 'to' should be a trader?
    require(to != _token0 && to != _token1, 'TokenSwap: INVALID_TO');
    //TODO: need confirmation: checking again (amount0Out > 0) because one of amount0Out or amount1Out must be 0
    //sending token to trader
    if(amount0Out > 0) _safeTransfer(_token0, to, amount0Out);  // TODO: why '_safeTransfer' instead of IERC20(_token0).transfer(...) ?
    if(amount1Out > 0) _safeTransfer(_token1, to, amount1Out);
    //TODO: where is the real implementation of "tokenSwapCall"? and what's the purpose? I guess it's a sort of callback for a custom function?
    if(data.length > 0) ITokenSwapCallee(to).tokenSwapCall(msg.sender, amount0Out, amount1Out, data);

    balance0 = IERC20(_token0).balance0(address(this));
    balance1 = IERC20(_token1).balance0(address(this));
    }


    /**
    token that is sent from trader to the pool.
    calculate how much trader sent.
    trader sends one type of tokens (ex: token0) and receive other token (ex: token1)
    so, one of them (amount0In and amount1In) is going to be 0 because trader didn't send
    */
    uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
    uint amount1In = balance1 > _reserve1 - amount1Out ? balance0 - (_reserve1 - amount1Out) : 0;

    // One of then must be greater than 0 because trader must sent at least one token to swap
    require(amount0In > 0 || amount1In > 0, 'TokenSwap: INSUFFICIENT_INPUT_AMOUNT');
    {
    /**
    TODO: Is this logic to calculate fee?
    TODO: why scaling multiplying 1000? It's because Solidity doesn't have decimal for 0.3%?
    TODO: 3 stands for 0.3% of fee for token swap
    TODO: Where is the logic that checks 0.3% properly received?
    */
    uint balance0Adjusted = (balance0 * 1000) - (amount0In * 3);
    uint balance1Adjusted = (balance1 * 1000) - (amount1In * 3);
    
    //TODO: what's the purpose of this check? the adjusted version should be always bigger?
    require(balance0Adjusted * balance1Adjusted >= uint(_reserve0) * uint(_reserve1) * 1000**2, 'TokenSwap: K');
    }

    _update(balance0, balance1, _reserve0, _reserve1);
    emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
  }

  function skim(address to) external lock {
    address _token0 = token0; // TODO: why gas saving? it's because of warm access?
    address _token1 = token1; // TODO: why gas saving?


    // TODO: where can I use this function?
    _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)) - reserve0);
    _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)) - reserve1);
  }

  /**
  Sync between token0 and token1 contracts with this contract's reserve0, reserve1
  reserve0, reserve1 are reflection of token0 and token1 contract's tokens
  */
  function sync() external lock {
    _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
  }
}
