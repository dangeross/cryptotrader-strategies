datasources = require 'datasources'
params = require 'params'
trading = require 'trading'
talib = require 'talib'

# primary datasource
# datasources.add 'kraken', 'xbt_eur', '1h'

# secondary datasources
datasources.add 'kraken', 'eth_eur', '1h', 250
datasources.add 'kraken', 'xmr_eur', '1h', 250

# Params
_currency = params.add 'Currency Limit', 250
_fee = params.add 'Order Fee (%)', 0.26
_minimumOrder = params.add 'Order Minimum', 0.01
_timeout = params.add 'Order Timeout', 60
_type = params.addOptions 'Order Type', ['market', 'limit'], 'market'
_smoothing = params.add 'Smoothing', 2

# Constants      
PAIR_STATES = 
  idle : 0
  canSell : 1
  canBuy : 2
  bought: 3

# Classes
class Functions
    @donchianMax: (inReal, optInTimePeriod) ->
        _.max(_.slice(inReal, inReal.length - optInTimePeriod))
    @donchianMin: (inReal, optInTimePeriod) ->
        _.min(_.slice(inReal, inReal.length - optInTimePeriod))
    @instrumentValue: (instrument, indicator, offset = 0) ->
        instrument[indicator][instrument[indicator].length - 1 - offset]
        
class Portfolio
    constructor: (options) ->
        @ticks = 0
        @pairs = []
        @options = options

    add: (pair) ->
        primary = (@pairs.length == 0)
        @pairs.push(pair)
        pair.setPrimary(primary)
        
    count: (state) ->
        _.filter(@pairs, {state: state}).length
        
    restore: (pairs) ->
        debug "************ Portfolio Restored **************"    

        for pairData in pairs
            pair = new Pair(pairData.market, pairData.name, pairData.interval, pairData.size)
            pair.restore(pairData.state, pairData.price, pairData.volume)
            @add(pair)
            
    save: (storage) ->
        storage.pairs = []
        
        for pair in @pairs
            storage.pairs.push(pair.save())
            
    stop: (instruments, options) ->
        for pair in @pairs
            instrument = datasources.get(pair.market, pair.name, pair.interval)
            pair.stop(instrument, options)
        
    update: (instruments, options) ->
        @ticks++  
        
        for pair in @pairs
            instrument = datasources.get(pair.market, pair.name, pair.interval)
            pair.update(instrument, options)
            pair.sell(instrument, options)
            
        for pair in @pairs
            instrument = datasources.get(pair.market, pair.name, pair.interval)
            limit = options.currency / (@pairs.length - @count(PAIR_STATES.bought))
            pair.buy(instrument, options, limit)

class Pair
    constructor: (market, name, interval, size = 100) ->
        @ticks = 0
        @market = market
        @name = name
        @interval = interval
        @size = size
        @state = PAIR_STATES.idle
        @primary = false
        
    setPrimary: (primary) ->
        @primary = primary
             
    restore: (state, price, volume) ->
        debug "*********** Pair #{@name} Restored *************"    

        @state = state
        @price = price
        @volume = volume
        
    save: () ->
        market: @market
        name: @name
        interval: @interval
        size: @size
        state: @state
        price: @price
        volume: @volume
        
    stop: (instrument, options) ->
        if @state == PAIR_STATES.bought
            @state = PAIR_STATES.canSell
            @sell(instrument, options)
        
    update: (instrument, options) ->
        price = instrument.price

        ema = talib.EMA
            inReal: instrument.close
            startIdx: 0
            endIdx: instrument.close.length - 1
            optInTimePeriod: options.emaPeriod
            
        @ema = _.last(ema)
        @dMax = Functions.donchianMax(ema, options.donchianPeriod)
        @dMin = Functions.donchianMin(ema, options.donchianPeriod)
        
        if @state == PAIR_STATES.bought
            @ticks++
            debug "P/L:  #{instrument.asset()} #{@percentChange(@price, price)}% 4h: #{@profit(instrument, 4)}% 24h: #{@profit(instrument, 24)}%"
        
        if @primary
            plot
                ema: @ema
                dMax: @dMax
                dMin: @dMin
            
        if instrument.price >= @dMax and @state != PAIR_STATES.bought
            @state = PAIR_STATES.canBuy
        else if instrument.price <= @dMin and @state == PAIR_STATES.bought
            @state = PAIR_STATES.canSell
        
        if @state != PAIR_STATES.bought
            debug "DMX: #{instrument.asset()} #{@percentChange(@dMax, price)}% 4h: #{@profit(instrument, 4)}% 24h: #{@profit(instrument, 24)}%"
            
    buy: (instrument, options, limit) ->
        if @state == PAIR_STATES.canBuy
            ticker = trading.getTicker instrument
            price = ticker.buy
            volume = (limit / price) * (1 - options.fee)
            
            if volume >= options.tradeMinimum
                try
                    debug "BUY #{volume} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{volume * price}"
                    
                    if trading.buy(instrument, options.tradeType, volume, price, options.timeout)
                        options.currency -= (price * volume) * (1 + options.fee)
                        debug "CUR: #{options.currency}"
                        @state = PAIR_STATES.bought
                        @volume = volume
                        @price = price
                    else 
                        @state = PAIR_STATES.idle
                        debug "BUY FAILED: #{volume} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{volume * price}"
                        sendEmail "BUY FAILED: #{volume} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{volume * price}"
                catch error
                    @state = PAIR_STATES.idle
                    debug "BUY FAILED: #{volume} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{volume * price}. #{error}"
                    sendEmail "BUY FAILED: #{volume} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{volume * price}. #{error}"
            else
                debug "BUY volume insufficient: #{volume} #{instrument.asset()}"
                @state = PAIR_STATES.idle
                
    profit: (instrument, offset) ->
        @percentChange(Functions.instrumentValue(instrument, 'close', offset), instrument.price)
        
    percentChange: (oldPrice, newPrice) ->
        period = ((newPrice - oldPrice) / oldPrice) * 100
        period.toFixed(2)

    sell: (instrument, options) ->
        if @state == PAIR_STATES.canSell
            ticker = trading.getTicker instrument
            price = ticker.sell
            volume = @volume
            
            debug "SELL #{volume} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{volume * price}"

            try
                if trading.sell(instrument, options.tradeType, volume, price, options.timeout)
                    options.currency += (price * volume) * (1 - options.fee)
                    debug "CUR: #{options.currency}"
                    @state = PAIR_STATES.idle
                    @ticks = 0
                    @volume = null
                    @price = null
                else
                    debug "SELL FAILED: #{volume} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{volume * price}"
                    sendEmail "SELL FAILED: #{volume} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{volume * price}"
            catch error
                debug "SELL FAILED: #{volume} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{volume * price}. #{error}"
                sendEmail "SELL FAILED: #{volume} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{volume * price}. #{error}"

init: ->
    debug "*********** Instance Initialised *************"    
    @context.options = 
        donchianPeriod: 26
        emaPeriod: _smoothing
        fee: _fee / 100
        currency: _currency
        tradeMinimum: _minimumOrder
        tradeType: _type
        timeout: _timeout
    
handle: ->
    debug "**********************************************"
    
    if !@storage.params
        @storage.params = @context.options
    
    if !@context.portfolio
        @context.portfolio = new Portfolio(@context.options)
        @context.portfolio.add(new Pair('kraken', 'xbt_eur', '1h', 250))
        @context.portfolio.add(new Pair('kraken', 'eth_eur', '1h', 250))
        @context.portfolio.add(new Pair('kraken', 'xmr_eur', '1h', 250))
    
    @context.portfolio.update(@data.instruments, @context.options)
    @context.portfolio.save(@storage)
    @storage.options = @context.options
    
onStop: ->
    debug "************* Instance Stopped ***************"
    @context.portfolio.stop(@data.instruments, @context.options)

onRestart: ->
    debug "************ Instance Restarted **************"

    if @storage.pairs
        @context.portfolio = new Portfolio(@context.options)
        @context.portfolio.restore(@storage.pairs)

    if @storage.options
        debug "************* Options Restored ***************"
        _.each @context.options, (value, key) ->
            if key == 'currency' and @storage.params.currency != value
                @storage.options.currency = value - (@storage.params.currency - @storage.options.currency)
            else if @storage.params[key] != value
                @storage.options[key] = value
            debug "PARAM[#{key}]: #{@storage.options[key]}"
        
        @context.options = @storage.params = @storage.options
