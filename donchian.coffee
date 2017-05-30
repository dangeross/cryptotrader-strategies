params = require 'params'
trading = require 'trading'
talib = require 'talib'

_fee = params.add 'Fee', 0.26
_limit = params.add 'Limit', 250
_volume = params.add 'Order Minimum', 0.01

class Functions
    @ema: (instrument, optInTimePeriod, lag = 0) ->
        results = talib.EMA
            inReal: instrument.close
            startIdx: 0
            endIdx: instrument.close.length - 1 - lag
            optInTimePeriod: optInTimePeriod
        _.last(results)
    @macd: (instrument, optInFastPeriod, optInSlowPeriod, optInSignalPeriod, lag = 0) ->
        results = talib.MACD
            inReal: instrument.close
            startIdx: 0
            endIdx: instrument.close.length - 1 - lag
            optInFastPeriod: optInFastPeriod
            optInSlowPeriod: optInSlowPeriod
            optInSignalPeriod: optInSignalPeriod
        result =
            macd: _.last(results.outMACD)
            signal: _.last(results.outMACDSignal)
            histogram: _.last(results.outMACDHist)
    @rsi: (instrument, optInTimePeriod) ->
        results = talib.RSI
            inReal: instrument.close
            startIdx: 0
            endIdx: instrument.close.length - 1
            optInTimePeriod: optInTimePeriod
        _.last(results)
    @sar: (instrument, optInAcceleration, optInMaximum) ->
        results = talib.SAR
            high: instrument.high
            low: instrument.low
            startIdx: 0
            endIdx: instrument.high.length - 1
            optInAcceleration: optInAcceleration
            optInMaximum: optInMaximum
        _.last(results)
    @donchianMax: (instrument, optInTimePeriod) ->
        _.max(_.slice(instrument.close, instrument.close.length - optInTimePeriod))
    @donchianMin: (instrument, optInTimePeriod) ->
        _.min(_.slice(instrument.close, instrument.close.length - optInTimePeriod))

class State
    buy: (price, volume) ->
        @position = 'LONG'
        @price = price
        @volume = volume
    sell: (price, volume) ->
        @position = 'SHORT'
        @price = price
        @volume = volume
    total: ->
        @price * @volume
    cancel: ->
        @position = null


init: (context)->
    context.emaPeriod = 2
    context.rsiPeriod = 14
    context.sarAcceleration = 0.025
    context.sarMaximum = 0.01
    context.macdThreshold = 0.03
    
    context.tradeMinimum = _volume
    context.tradeFee = _fee / 100
    context.state = new State(_fee)

    setPlotOptions
        rsi:
            color: 'rgba(44,44,44,0.2)'
            secondary: true
        macd:
            color: 'rgba(0,200,0,0.4)'
            secondary: true
        sign:
            color: 'rgba(200,0,0,0.2)'
            secondary: true
        hist:
            color: 'rgba(200,200,0,0.3)'
            secondary: true
            
valueMinusFee: (value, fee) ->
    value - (value * fee) 
    
valuePlusFee: (value, fee) ->
    value + (value * fee)
            
availableCurrency: (context) ->
    @valueMinusFee(context.currencyLimit, context.tradeFee)
    
availableVolume: (context, instrument) ->
    @availableCurrency(context) / instrument.price
    
availableAssets: (context, instrument) ->
    Math.min(context.assetLimit, @valueMinusFee(context.assetLimit * instrument.price, context.tradeFee))

handle: (context, data)->
    instrument  = data.instruments[0]
    price = instrument.price
    
    currency = @portfolio.positions[instrument.curr()]
    asset = @portfolio.positions[instrument.asset()]
    value = (asset.amount * instrument.price) + currency.amount
    
    if context.assetLimit == undefined
        context.currencyLimit = Math.min(_limit, currency.amount)
        context.assetLimit = Math.min(currency.amount / instrument.price, asset.amount)

    emaFast = Functions.ema(instrument, 10)
    emaSlow = Functions.ema(instrument, 21)
    emaSlowPrev = Functions.ema(instrument, 21, 1)
    rsi = Functions.rsi(instrument, context.rsiPeriod)
    macd = Functions.macd(instrument, 10, 26, 9)
    sar = Functions.sar(instrument, context.sarAcceleration, context.sarMaximum)
    
    dMax = Functions.donchianMax(instrument, 24)
    dMin = Functions.donchianMin(instrument, 24)
    
    #debug "#{dMax} #{instrument.price} #{dMin}"

    plot
        emaFast: emaFast
        emaSlow: emaSlow
        #rsi: rsi
        #sar: sar
        #macd: macd.macd
        #sign: macd.signal
        #hist: macd.histogram
        dMax: dMax
        dMin: dMin
        
    diff = 100 * (emaFast - emaSlow) / ((emaFast + emaSlow) / 2)
    
    # Uncomment next line for some debugging
    if price >= dMax    
        context.state.buy(instrument.price, @availableVolume(context, instrument));
        debug "#{instrument.curr()} #{currency.amount} + #{instrument.asset()} #{asset.amount} = #{value}"
        debug "BUY LONG #{context.state.volume} @ #{context.state.price} = #{context.state.total()} (#{@valuePlusFee(context.state.total(), context.tradeFee)})"

        if context.state.volume > context.tradeMinimum and trading.buy instrument, 'market', context.state.volume
            context.currencyLimit -= @valuePlusFee(context.state.total(), context.tradeFee)
            context.assetLimit += context.state.volume
            debug "LIMIT #{context.currencyLimit} / #{context.assetLimit}"
        else
            context.state.cancel
    else if price <= dMin
        context.state.sell(instrument.price, @availableAssets(context, instrument));
        debug "#{instrument.curr()} #{currency.amount} + #{instrument.asset()} #{asset.amount} = #{value}"
        debug "SELL SHORT #{context.state.volume} @ #{context.state.price} = #{context.state.total()} (#{@valuePlusFee(context.state.total(), context.tradeFee)})"

        if context.state.volume > context.tradeMinimum and trading.sell instrument, 'market', context.state.volume
            context.assetLimit -= context.state.volume
            context.currencyLimit += @valuePlusFee(context.state.total(), context.tradeFee)
            debug "LIMIT #{context.currencyLimit} / #{context.assetLimit}"
        else
            context.state.cancel
 
