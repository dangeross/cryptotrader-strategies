params = require 'params'
trading = require 'trading'
talib = require 'talib'

_limit = params.add 'Pair Limit (%) ', 50
_volume = params.add 'Order Minimum  ', 0.01

class Functions
    @ema: (instrument, optInTimePeriod, lag = 0) ->
        results = talib.EMA
            inReal: instrument.close
            startIdx: 0
            endIdx: instrument.close.length - 1 - lag
            optInTimePeriod: optInTimePeriod
        _.last(results)
    @donchianMax: (instrument, optInTimePeriod) ->
        _.max(_.slice(instrument.close, instrument.close.length - optInTimePeriod))
    @donchianMin: (instrument, optInTimePeriod) ->
        _.min(_.slice(instrument.close, instrument.close.length - optInTimePeriod))

init: (context)->
    context.emaPeriod = 2
    context.donchianPeriod = 26

    context.tradeLimit = _limit / 100
    context.tradeMinimum = _volume

availableCurrency: (currency) ->
    currency.amount * @context.tradeLimit
    
availableVolume: (currency, instrument) ->
    @availableCurrency(currency) / instrument.price
    
availableAssets: (asset) ->
    asset.amount * @context.tradeLimit

handle: (context, data)->
    instrument  = data.instruments[0]
    price = instrument.price
    
    currency = @portfolio.positions[instrument.curr()]
    asset = @portfolio.positions[instrument.asset()]
    value = (asset.amount * price) + currency.amount

    ema = Functions.ema(instrument, context.emaPeriod)
    dMax = Functions.donchianMax(instrument, context.donchianPeriod)
    dMin = Functions.donchianMin(instrument, context.donchianPeriod)
    
    #debug "#{dMax} #{price} #{dMin}"

    plot
        ema: ema
        dMax: dMax
        dMin: dMin
        
    if price >= dMax and context.position != 'LONG'
        volume = @availableVolume(currency, instrument)
        debug "#{instrument.curr()} #{currency.amount} + #{instrument.asset()} #{asset.amount} = #{value}"
        debug "BUY #{volume} @ #{price} = #{volume * price}"

        if volume > context.tradeMinimum and trading.buy instrument, 'market', volume
            context.position = 'LONG'
            context.price = price
            context.volume = volume
    else if price <= dMin and context.position != 'SHORT'
        volume = @availableAssets(asset)
        debug "#{instrument.curr()} #{currency.amount} + #{instrument.asset()} #{asset.amount} = #{value}"
        debug "SELL #{volume} @ #{price} = #{volume * price}"

        if volume > context.tradeMinimum and trading.sell instrument, 'market', volume
            context.position = 'SHORT'
            context.price = price
            context.volume = volume
