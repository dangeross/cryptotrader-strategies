params = require 'params'
trading = require 'trading'
talib = require 'talib'

_smoothing = params.add 'Smoothing', 2
_buffer = params.add 'Buffer (%)', 30
_assetLimit = params.add 'Asset Limit (%)', 50
_currencyLimit = params.add 'Currency Limit (%)', 50
_volume = params.add 'Order Minimum', 0.01

class Functions
    @ema: (inReal, optInTimePeriod, lag = 0) ->
        results = talib.EMA
            inReal: inReal
            startIdx: 0
            endIdx: inReal.length - 1 - lag
            optInTimePeriod: optInTimePeriod
        _.last(results)
    @donchianMax: (inReal, optInTimePeriod) ->
        _.max(_.slice(inReal, inReal.length - optInTimePeriod))
    @donchianMin: (inReal, optInTimePeriod) ->
        _.min(_.slice(inReal, inReal.length - optInTimePeriod))

init: (context)->
    context.donchianPeriod = 26

    context.emaPeriod = _smoothing
    context.buffer = _buffer / 100
    context.assetLimit = _assetLimit / 100
    context.currencyLimit = _currencyLimit / 100
    context.tradeMinimum = _volume

availableCurrency: (currency) ->
    currency.amount * @context.currencyLimit
    
availableVolume: (currency, instrument) ->
    @availableCurrency(currency) / instrument.price
    
availableAssets: (asset) ->
    asset.amount * @context.assetLimit

handle: (context, data)->
    instrument  = data.instruments[0]
    price = instrument.price
    
    currency = @portfolio.positions[instrument.curr()]
    asset = @portfolio.positions[instrument.asset()]
    value = (asset.amount * price) + currency.amount
    
    ema = talib.EMA
        inReal: instrument.close
        startIdx: 0
        endIdx: instrument.close.length - 1
        optInTimePeriod: context.emaPeriod

    dMax = Functions.donchianMax(ema, context.donchianPeriod)
    dMin = Functions.donchianMin(ema, context.donchianPeriod)
    
    dDiff = (dMax - dMin)
    dMinBuf = dMin + (dDiff * context.buffer)
    dMaxBuf = dMax - (dDiff * context.buffer)
    dAvg = dMin + ((dMax - dMin) / 2);
    
    #debug "#{dMax} #{price} #{dMin}"

    plot
        ema: _.last(ema)
        dMax: dMax
        dMin: dMin
        dMinBuf: dMinBuf
        dMaxBuf: dMaxBuf
        dAvg: dAvg
        
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
