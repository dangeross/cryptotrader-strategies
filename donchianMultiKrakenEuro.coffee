datasources  = require 'datasources'
params = require 'params'
trading = require 'trading'
talib = require 'talib'

# primary datasource
# datasources.add 'kraken', 'xbt_eur', '1h'

# secondary datasources
datasources.add 'kraken', 'eth_eur', '1h', 250
datasources.add 'kraken', 'xmr_eur', '1h', 250

# Params
_limit = params.add 'Currency Limit', 250
_volume = params.add 'Assets Bought', 0
_fee = params.add 'Order Fee (%)', 0.26
_minimumOrder = params.add 'Order Minimum', 0.01
_timeout = params.add 'Order Timeout', 60
_smoothing = params.add 'Smoothing', 2

# Constants      
PAIR_STATES = 
  idle : 0
  canBuy : 1
  canSell : 2
  bought: 3

# Classes
class Functions
    @donchianMax: (inReal, optInTimePeriod) ->
        _.max(_.slice(inReal, inReal.length - optInTimePeriod))
    @donchianMin: (inReal, optInTimePeriod) ->
        _.min(_.slice(inReal, inReal.length - optInTimePeriod))
        
class Portfolio
    @constructor: (options) ->
        @ticks = 0
        @pairs = []
        @options = options

    @add: (pair) ->
        @pairs.push(pair)
        
    @update: (instruments) ->
        @ticks++  

class Pair
    @constructor: (market, name, interval, size = 100) ->
        @market = market
        @name = name
        @interval = interval
        @size = size
        @state = PAIR_STATES.idle
        
    @update: () ->
        
    @trade: () ->
    
    
        

init: (context) ->
    context.options
        donchianPeriod: 26
        emaPeriod: _smoothing
        fee: _fee / 100
        limit: _limit
        tradeMinimum: _minimumOrder
        timeout: _timeout
    
    context.portfolio = new Portfolio(context.options)
    context.portfolio.add(new Pair('kraken', 'xbt_eur', '1h', 250))
    context.portfolio.add(new Pair('kraken', 'eth_eur', '1h', 250))
    context.portfolio.add(new Pair('kraken', 'xmr_eur', '1h', 250))

availableCurrency: (currency) ->
    @context.currencyLimit - (@context.currencyLimit * @context.fee)
    
availableVolume: (currency, instrument) ->
    @availableCurrency(currency) / instrument.price
    
availableAssets: (asset) ->
    asset.amount * @context.assetLimit
    
handle: (context, data) ->
    context.portfolio.update(data.instruments)
    
    
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
    
    #debug "#{dMax} #{price} #{dMin}"

    plot
        ema: _.last(ema)
        dMax: dMax
        dMin: dMin
        
    if price >= dMax and context.position != 'BUY'
        volume = @availableVolume(currency, instrument)
        debug "#{instrument.curr()} #{currency.amount} + #{instrument.asset()} #{asset.amount} = #{value}"
        debug "BUY #{volume} @ #{price} = #{volume * price}"

        if volume > context.tradeMinimum and trading.buy instrument, 'market', volume, price, context.timeout
            context.position = 'BUY'
            context.price = price
            context.volume = volume
    else if price <= dMin and context.position == 'BUY'
        debug "#{instrument.curr()} #{currency.amount} + #{instrument.asset()} #{asset.amount} = #{value}"
        debug "SELL #{context.volume} @ #{price} = #{context.volume * price}"

        if context.volume > context.tradeMinimum and trading.sell instrument, 'market', context.volume, price, context.timeout
            context.currencyLimit = context.volume * price
            context.currencyLimit = @availableCurrency(currency)
            
            context.position = 'SELL'
            context.price = price
            context.volume = volume
