datasources = require 'datasources'
params = require 'params'
trading = require 'trading'
talib = require 'talib'

# primary datasource
# datasources.add 'kraken', 'xmr_xbt', '1h'

# secondary datasources
datasources.add 'kraken', 'etc_xbt', '1h', 250
datasources.add 'kraken', 'zec_xbt', '1h', 250
datasources.add 'kraken', 'icn_xbt', '1h', 250

# Params
_currency = params.add 'Currency Limit', 250
_fee = params.add 'Order Fee (%)', 0.26
_minimumOrder = params.add 'Order Minimum', 0.01
_timeout = params.add 'Order Timeout', 60
_period = params.add 'Enter/Exit Period', 26
_smoothing = params.add 'Smoothing', 2
_sellOnStop = params.add 'Sell On Stop', true

# Constants      
PAIR_STATES = 
  idle : 0
  canSell : 1
  canBuy : 2
  bought: 3

# Classes
class Indicators
    @donchianMax: (inReal, optInTimePeriod) ->
        _.max(_.slice(inReal, inReal.length - optInTimePeriod))
    @donchianMin: (inReal, optInTimePeriod) ->
        _.min(_.slice(inReal, inReal.length - optInTimePeriod))
    @instrumentValue: (instrument, indicator, offset = 0) ->
        instrument[indicator][instrument[indicator].length - 1 - offset]
        
class Helpers
    @round: (number, roundTo = 8) ->
        Number(Math.round(number + 'e' + roundTo) + 'e-' + roundTo);
    @floatAddition: (numberA, numberB, presision = 16) ->
        pow = Math.pow(10, presision)
        ((numberA * pow) + (numberB * pow)) / pow

class IceTrade
    @buy: (instrument, currency, options, limit, roundTo) ->
        debug "START BUY #{limit} #{instrument.curr()}"
        limit *= (1 - options.fee)
        attempts = 0
        finalAttempt = false
        maxOrderVolume = (limit / instrument.price) / 10
        result = 
            gross: 0
            net: 0
            price: 0
            volume: 0
        while true
            attempts++
            ticker = trading.getTicker instrument
            price = ticker.buy * 1.0001
            volume = options.tradeMinimum + ((0.8 + 0.2 * Math.random()) * maxOrderVolume)
            if result.net + (volume * price) >= limit or (limit - result.net - (volume * price * (1 + options.fee))) / price < options.tradeMinimum
                price = ticker.buy
                volume = (limit - result.net) / price
                finalAttempt = true
            if result.net + (volume * price) >= currency.amount
                price = ticker.buy
                volume = currency.amount / price
                finalAttempt = true
            try
                if finalAttempt
                    debug "FINAL BUY #{attempts}: #{volume} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{volume * price}"
                        
                    if trading.buy(instrument, 'limit', volume, price, options.timeout)
                        result.gross += (price * volume)
                        result.net = result.gross * (1 + options.fee)
                        result.volume = Helpers.floatAddition(result.volume, volume)
                        result.price = result.gross / result.volume
                        break
                    else
                        debug "BUY FAILED"
                debug "BUY #{attempts} #{volume} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{volume * price}"
                if trading.buy(instrument, 'limit', volume, price, options.timeout)
                    result.gross += (price * volume)
                    result.net = result.gross * (1 + options.fee)
                    result.volume = Helpers.floatAddition(result.volume, volume)
                    result.price = result.gross / result.volume
                else
                    debug "BUY FAILED"
            catch error
                warn "BUY FAILED: #{error}"
                break
            if attempts > 20
                break
        debug "ICE COMPLETED #{result.gross} (#{result.net}) / #{result.volume} = #{result.price}"
        result
    @sell: (instrument, asset, options, limit, roundTo) ->
        debug "START SELL #{limit}  #{instrument.asset()}"
        attempts = 0
        finalAttempt = false
        maxOrderVolume = limit / 10
        result = 
            gross: 0
            net: 0
            price: 0
            volume: 0
        while true
            attempts++
            ticker = trading.getTicker instrument
            price = ticker.sell * 0.9999
            volume = Math.max((0.9 + 0.2 * Math.random()) * maxOrderVolume, options.tradeMinimum * (1.0 + 0.1 * Math.random()))
            if result.volume + volume >= limit or limit - (result.volume + volume) <= options.tradeMinimum
                volume = limit - result.volume
                finalAttempt = true
            if volume > asset.amount
                volume = asset.amount
                finalAttempt = true
            try
                if finalAttempt
                    price = ticker.sell
                    debug "FINAL SELL #{attempts}: #{result.volume} #{volume} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{volume * price}"
                      
                    if trading.sell(instrument, 'limit', volume, price, options.timeout)
                        result.gross += (price * volume)
                        result.net = result.gross * (1 - options.fee)
                        result.volume = Helpers.floatAddition(result.volume, volume)
                        result.price = result.gross / result.volume
                        break
                    else
                        debug "SELL FAILED"
                debug "SELL #{attempts} #{volume} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{volume * price}"
                if trading.sell(instrument, 'limit', volume, price, options.timeout)
                    result.gross += (price * volume)
                    result.net = result.gross * (1 - options.fee)
                    result.volume = Helpers.floatAddition(result.volume, volume)
                    result.price = result.gross / result.volume
                else
                    debug "SELL FAILED"
            catch error
                warn "SELL FAILED: #{error}"
                break
            if attempts > 20
                break
        debug "ICE COMPLETED #{result.gross} (#{result.net}) / #{result.volume} = #{result.price}"
        result
        
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
            pair.restore(pairData.profit, pairData.state, pairData.price, pairData.volume)
            @add(pair)
            
    save: (storage) ->
        storage.pairs = []
        
        for pair in @pairs
            storage.pairs.push(pair.save())
            
    stop: (portfolios, instruments, options) ->
        for pair in @pairs
            instrument = datasources.get(pair.market, pair.name, pair.interval)
            pair.stop(portfolios, instrument, options)
        
    update: (portfolios, instruments, options) ->
        @ticks++  
        
        for pair in @pairs
            instrument = datasources.get(pair.market, pair.name, pair.interval)
            pair.update(instrument, options)
            pair.sell(portfolios, instrument, options)
            
        for pair in @pairs
            instrument = datasources.get(pair.market, pair.name, pair.interval)
            limit = options.currency / (@pairs.length - @count(PAIR_STATES.bought))
            pair.buy(portfolios, instrument, options, limit)
            
        if @ticks % 24 == 0
            for pair in @pairs
                instrument = datasources.get(pair.market, pair.name, pair.interval)
                pair.report(instrument, options)

class Pair
    constructor: (market, name, interval, size = 100, roundTo = 8) ->
        @ticks = 0
        @profit = 0
        @market = market
        @name = name
        @interval = interval
        @size = size
        @roundTo = roundTo
        @state = PAIR_STATES.idle
        @primary = false
        
    setPrimary: (primary) ->
        @primary = primary
             
    restore: (profit = 0, state, price, volume) ->
        debug "*********** Pair #{@name} Restored *************"    

        @profit = profit
        @state = state
        @price = price
        @volume = volume
        
    save: () ->
        market: @market
        name: @name
        interval: @interval
        size: @size
        roundTo: @roundTo
        profit: @profit
        state: @state
        price: @price
        volume: @volume
        
    stop: (positions, instrument, options) ->
        if @state == PAIR_STATES.bought
            @state = PAIR_STATES.canSell
            @sell(positions, instrument, options)
                            
    instrumentChange: (instrument, offset) ->
        @percentChange(Indicators.instrumentValue(instrument, 'close', offset), instrument.price)
        
    percentChange: (oldPrice, newPrice) ->
        period = ((newPrice - oldPrice) / oldPrice) * 100
        period.toFixed(2)
            
    report: (instrument, options) ->
        if @profit > 0
            info "EARNINGS #{instrument.asset().toUpperCase()}: #{@profit.toFixed(5)} #{instrument.curr()}"
        else
            warn "EARNINGS #{instrument.asset().toUpperCase()}: #{@profit.toFixed(5)} #{instrument.curr()}"

    update: (instrument, options) ->
        price = instrument.price

        # Analyse instrument
        ema = talib.EMA
            inReal: instrument.close
            startIdx: 0
            endIdx: instrument.close.length - 1
            optInTimePeriod: options.emaPeriod
            
        @ema = _.last(ema)
        @dMax = Indicators.donchianMax(ema, options.donchianPeriod)
        @dMin = Indicators.donchianMin(ema, options.donchianPeriod)
        
        if @state == PAIR_STATES.bought
            @ticks++
            profitLoss = ((price * @volume) * (1 - options.fee)) - ((@price * @volume) * (1 + options.fee))
            
            if profitLoss > 0
                info "#{instrument.asset().toUpperCase()}: #{profitLoss.toFixed(5)} #{instrument.curr()} #{@percentChange(@price, price)}%, #{@instrumentChange(instrument, 4)}% 4h, #{@instrumentChange(instrument, 24)}% 24h"
            else
                warn "#{instrument.asset().toUpperCase()}: #{profitLoss.toFixed(5)} #{instrument.curr()} #{@percentChange(@price, price)}%, #{@instrumentChange(instrument, 4)}% 4h, #{@instrumentChange(instrument, 24)}% 24h"
        
        # Plot graph
        if @primary
            plot
                ema: @ema
                dMax: @dMax
                dMin: @dMin
            
        # Test buy/sell conditions
        if instrument.price >= @dMax and @state != PAIR_STATES.bought
            @state = PAIR_STATES.canBuy
        else if instrument.price <= @dMin and @state == PAIR_STATES.bought
            @state = PAIR_STATES.canSell
        
        if @state != PAIR_STATES.bought
            debug "#{instrument.asset().toUpperCase()}: #{@percentChange(@dMax, price)}% dM, #{@instrumentChange(instrument, 4)}% 4h, #{@instrumentChange(instrument, 24)}% 24h"
            
    buy: (portfolios, instrument, options, limit) ->
        if @state == PAIR_STATES.canBuy
            currency = portfolios[@market].positions[instrument.curr()]
            portfolio = portfolios[@market]
            debug "START POSITION #{portfolio.positions[instrument.asset()].amount} #{instrument.asset()} : #{portfolio.positions[instrument.curr()].amount} #{instrument.curr()}"
            trade = IceTrade.buy(instrument, currency, options, limit, @roundTo)
            if trade.volume > 0
                if options.currency - trade.net < 0 
                    options.currency = 0 
                else 
                    options.currency -= trade.net
                debug "CUR: #{options.currency}"
                @state = PAIR_STATES.bought
                @volume = trade.volume
                @price = trade.price
            else
                @state = PAIR_STATES.idle
            debug "END POSITION #{portfolio.positions[instrument.asset()].amount} #{instrument.asset()} : #{portfolio.positions[instrument.curr()].amount} #{instrument.curr()}"

    sell: (portfolios, instrument, options) ->
        if @state == PAIR_STATES.canSell
            asset = portfolios[@market].positions[instrument.asset()]
            portfolio = portfolios[@market]
            debug "START POSITION #{portfolio.positions[instrument.asset()].amount} #{instrument.asset()} : #{portfolio.positions[instrument.curr()].amount} #{instrument.curr()}"
            trade = IceTrade.sell(instrument, asset, options, @volume, @roundTo)
            if trade.net > 0
                options.currency += trade.net
                debug "CUR: #{options.currency}"
                @profit += trade.net - ((@price * @volume) * (1 + options.fee))
                @state = PAIR_STATES.idle
                @ticks = 0
                @volume = null
                @price = null
            debug "END POSITION #{portfolio.positions[instrument.asset()].amount} #{instrument.asset()} : #{portfolio.positions[instrument.curr()].amount} #{instrument.curr()}"

init: ->
    debug "*********** Instance Initialised *************"    
    @context.options = 
        donchianPeriod: _period
        emaPeriod: _smoothing
        fee: _fee / 100
        currency: _currency
        tradeMinimum: _minimumOrder
        timeout: _timeout
        sellOnStop: _sellOnStop
    
handle: ->
    debug "**********************************************"
    
    if !@storage.params
        @storage.params = _.clone(@context.options)
    
    if !@context.portfolio
        @context.portfolio = new Portfolio(@context.options)
        @context.portfolio.add(new Pair('kraken', 'xmr_xbt', '1h', 250))
        @context.portfolio.add(new Pair('kraken', 'etc_xbt', '1h', 250))
        @context.portfolio.add(new Pair('kraken', 'zec_xbt', '1h', 250))
        @context.portfolio.add(new Pair('kraken', 'icn_xbt', '1h', 250))
    
    @context.portfolio.update(@portfolios, @data.instruments, @context.options)
    @context.portfolio.save(@storage)
    @storage.options = @context.options
    
onStop: ->
    debug "************* Instance Stopped ***************"
    if @context.options.sellOnStop
        @context.portfolio.stop(@portfolios, @data.instruments, @context.options)

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
