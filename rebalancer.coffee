trading = require 'trading'

init: (context)->
    context.DISTANCE  = 5 # percent price distance of next rebalancing

handle: (context, data)->
    # data object provides access to the current candle
    instrument = data.instruments[0]
    fiatNow = portfolio.positions[instrument.curr()].amount
    btcNow = portfolio.positions[instrument.asset()].amount
    price = instrument.price
    
    btcValue = btcNow * price
    diff = fiatNow - btcValue
    diffBtc = diff / price
    mustBuy = diffBtc / 2
    percDiff = diffBtc / btcNow * 100
    
    # TRADE
    if Math.abs(percDiff) > context.DISTANCE
        if mustBuy > 0
            trading.buy instrument 'market', mustBuy
        else
            trading.sell instrument, 'market', Math.abs(mustBuy))
