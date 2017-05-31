params = require 'params'
trading = require 'trading'
talib = require 'talib'

_fee = params.add 'Fee', 0
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
    context.donchianPeriod = 26

    context.tradeMinimum = _volume
    context.tradeFee = _fee / 100
    context.state = new State(_fee)
            
valueMinusFee: (value, fee) ->
    value - (value * fee) 
    
valuePlusFee: (value, fee) ->
    value + (value * fee)
            
availableCurrency: (context) ->
    @valueMinusFee(context.currencyLimit, context.tradeFee)
    
availableVolume: (context, instrument) ->
    @availableCurrency(context) / instrument.price
    
availableAssets: (context, instrument) ->
    context.assetLimit

handle: (context, data)->
    instrument  = data.instruments[0]
    price = instrument.price
    
    currency = @portfolio.positions[instrument.curr()]
    asset = @portfolio.positions[instrument.asset()]
    value = (asset.amount * instrument.price) + currency.amount
    
    if context.assetLimit == undefined
        context.currencyLimit = Math.min(_limit, currency.amount)
        context.assetLimit = Math.min(context.currencyLimit / instrument.price, asset.amount)
        debug "LIMIT #{context.currencyLimit} / #{context.assetLimit}"

    ema = Functions.ema(instrument, context.emaPeriod)
    dMax = Functions.donchianMax(instrument, context.donchianPeriod)
    dMin = Functions.donchianMin(instrument, context.donchianPeriod)
    
    #debug "#{dMax} #{instrument.price} #{dMin}"

    plot
        ema: ema
        dMax: dMax
        dMin: dMin
        
    if price >= dMax    
        context.state.buy(instrument.price, @availableVolume(context, instrument));
        debug "#{instrument.curr()} #{currency.amount} + #{instrument.asset()} #{asset.amount} = #{value}"
        debug "BUY #{context.state.volume} @ #{context.state.price} = #{context.state.total()} (#{@valuePlusFee(context.state.total(), context.tradeFee)})"

        if context.state.volume > context.tradeMinimum and trading.buy instrument, 'market', context.state.volume
            context.currencyLimit -= @valuePlusFee(context.state.total(), context.tradeFee)
            context.assetLimit += context.state.volume
            debug "LIMIT #{context.currencyLimit} / #{context.assetLimit}"
        else
            context.state.cancel
    else if price <= dMin
        context.state.sell(instrument.price, @availableAssets(context, instrument));
        debug "#{instrument.curr()} #{currency.amount} + #{instrument.asset()} #{asset.amount} = #{value}"
        debug "SELL #{context.state.volume} @ #{context.state.price} = #{context.state.total()} (#{@valuePlusFee(context.state.total(), context.tradeFee)})"

        if context.state.volume > context.tradeMinimum and trading.sell instrument, 'market', context.state.volume
            context.assetLimit -= context.state.volume
            context.currencyLimit += @valuePlusFee(context.state.total(), context.tradeFee)
            debug "LIMIT #{context.currencyLimit} / #{context.assetLimit}"
        else
            context.state.cancel
