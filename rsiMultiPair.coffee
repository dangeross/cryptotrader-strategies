datasources = require 'datasources'
params = require 'params'
trading = require 'trading'
talib = require 'talib'

# primary datasource
# datasources.add 'kraken', 'xbt_eur', 1

# secondary datasources
datasources.add 'kraken', 'eth_eur', 1, 250
datasources.add 'kraken', 'etc_eur', 1, 250
datasources.add 'kraken', 'xmr_eur', 1, 250

# Params
_currency = params.add 'Currency Limit', 1000
_fee = params.add 'Order Fee (%)', 0.24
_maxOrders = params.add 'Max Orders/Pair', 5
_takeProfit = params.add 'Take Profit (%)', 2.5
_timeout = params.add 'Order Timeout', 60
_sellOnStop = params.add 'Sell On Stop', false

# Classes
class Helpers
    @countLows: (inReal, low) ->
        count = 0
        loop
            count++
            break if inReal[inReal.length - 1 - count] > low
        count
    @countHighs: (inReal, high) ->
        count = 0
        loop
            count++
            break if inReal[inReal.length - 1 - count] < high
        count
    @nth: (inReal, index) ->
        inReal[if index < 0 then inReal.length + index else index]
    @round: (number, roundTo = 8) ->
        Number(Math.round(number + 'e' + roundTo) + 'e-' + roundTo);
    @floatAddition: (numberA, numberB, presision = 16) ->
        pow = Math.pow(10, presision)
        ((numberA * pow) + (numberB * pow)) / pow
    @percentChange: (oldPrice, newPrice) ->
        ((newPrice - oldPrice) / oldPrice) * 100

class Indicators
    @macd: (inReal, optInFastPeriod, optInSlowPeriod, optInSignalPeriod, lag = 0) ->
        results = talib.MACD
            inReal: inReal
            startIdx: 0
            endIdx: inReal.length - 1 - lag
            optInFastPeriod: optInFastPeriod
            optInSlowPeriod: optInSlowPeriod
            optInSignalPeriod: optInSignalPeriod
        result =
            macd: _.last(results.outMACD)
            signal: _.last(results.outMACDSignal)
            histogram: _.last(results.outMACDHist)
        result
    @rsi: (inReal, optInTimePeriod, lag = 0) ->
        talib.RSI
            inReal: inReal
            startIdx: 0
            endIdx: inReal.length - 1 - lag
            optInTimePeriod: optInTimePeriod

class Portfolio
    constructor: (options) ->
        @ticks = 0
        @pairs = []
        @options = options

    add: (pair) ->
        primary = (@pairs.length == 0)
        @pairs.push(pair)

    restore: (pairs) ->
        debug "************ Portfolio Restored **************"

        for pairData in pairs
            pair = new Pair(pairData.market, pairData.name, pairData.interval, pairData.size)
            pair.restore(pairData.count, pairData.profit, pairData.trades)
            @add(pair)

    save: (storage) ->
        storage.pairs = []

        for pair in @pairs
            storage.pairs.push(pair.save())

    stop: (portfolios, instruments, options) ->
        for pair in @pairs
            portfolio = portfolios[pair.market]
            pair.stop(portfolio, options)

    update: (portfolios, instruments, options) ->
        @ticks++

        for pair in @pairs
            portfolio = portfolios[pair.market]
            pair.update(portfolio, options)
            if @ticks % 240 == 0
                pair.report(portfolio, options)

class Pair
    constructor: (market, name, interval, size = 100) ->
        @profit = 0
        @count = 0
        @market = market
        @name = name
        @interval = interval
        @size = size
        @trades = []

    restore: (count = 0, profit = 0, trades ) ->
        debug "*********** Pair #{@name} Restored *************"
        @count = count
        @profit = profit
        @trades = _.map trades, (trade) ->
            new Trade(trade.id, trade.volume, trade.price)

    save: () ->
        count: @count
        market: @market
        name: @name
        interval: @interval
        size: @size
        profit: @profit
        trades: _.map @trades, (trade) ->
            trade.serialize()

    stop: (portfolio, options) ->
        instrument = datasources.get(@market, @name, @interval)
        _.each(@trades, (trade) ->
            @sell(portfolio, instrument, options)
        , @)

    report: (portfolio, options) ->
        instrument = datasources.get(@market, @name, @interval)
        if @profit > 0
            info "EARNINGS #{instrument.asset().toUpperCase()}: #{@profit.toFixed(5)} #{instrument.curr()}"
        else
            warn "EARNINGS #{instrument.asset().toUpperCase()}: #{@profit.toFixed(5)} #{instrument.curr()}"

    update: (portfolio, options) ->
        instrument = datasources.get(@market, @name, @interval)
        price = instrument.price

        rsi = Indicators.rsi(instrument.close, 14, 0)
        rsiOld = Helpers.nth(rsi, -2)
        rsiNew = Helpers.nth(rsi, -1)

        #plot
        #    rsi: rsiNew

        if rsiOld <= 30 and rsiNew > 30 #and @trades.length < options.maxOrders
            # Buy
            @buy(portfolio, instrument, options)
        else if rsiOld >= 70 and rsiNew < 70
            # Sell
            _.each(
                _.filter(@trades, (trade) -> 
                    trade.takeProfit(portfolio, instrument, options))
                , (trade) -> @sell(portfolio, instrument, options, trade)
            , @)

    buy: (portfolio, instrument, options) ->
        tradeLimit = options.tradeLimit #(options.currency * 0.05) #options.tradeLimit
        limit = tradeLimit * (1 - options.fee)
        currency = portfolio.positions[instrument.base()]
        options.currency = if options.currency < currency.amount then currency.amount else options.currency

        if options.currency > limit
            currency = portfolio.positions[instrument.base()]
            ticker = trading.getTicker instrument
            price = Helpers.round(ticker.buy * 1.0001, 4)
            volume = Helpers.round(tradeLimit / price, 6)

            debug "BUY #{volume} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{volume * price}"

            try
                if trading.buy(instrument, 'limit', volume, price, options.timeout)
                    options.currency -= (price * volume) * (1 + options.fee)
                    @trades.push(new Trade(@count++, volume, price))
                else
                    debug "BUY FAILED"
                    plotMark
                        fail: price
            catch err
                debug "CUR: #{options.currency}"
                debug "ERR: #{err}: #{portfolio.positions[instrument.base()].amount}"

    sell: (portfolio, instrument, options, trade) ->
        asset = portfolio.positions[instrument.asset()]
        ticker = trading.getTicker instrument
        price = Helpers.round(ticker.sell * 0.9999, 4)
        volume = if asset.amount < trade.volume then asset.amount else trade.volume

        debug "SELL #{volume} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{volume * price}"

        try
            if trading.sell(instrument, 'limit', volume, price, options.timeout)
                options.currency += (price * volume) * (1 - options.fee)
                @profit += ((price * volume) * (1 - options.fee)) - ((trade.price * volume) * (1 + options.fee))
                debug "CURRENCY: #{options.currency} PROFIT: #{@profit}"
                _.remove(@trades, (item) -> item.id == trade.id)
            else
                debug "SELL FAILED: #{}"
                plotMark
                    fail: price
        catch err
            debug "ERR: #{err}: #{asset.amount}"

class Trade
    constructor: (id, volume, price) ->
        @id = id
        @volume = volume
        @price = price

    serialize: () ->
        id: @id
        volume: @volume
        price: @price
        
    takeProfit: (portfolio, instrument, options) ->
        ticker = trading.getTicker instrument
        price = Helpers.round(ticker.sell * 0.9999, 4)
        percentChange = Helpers.percentChange(@price, price)
        
        if percentChange >= options.takeProfit
            info "#{instrument.asset()}@#{@price}: #{percentChange.toFixed(2)}%"
        #else
        #    debug "#{instrument.asset()}@#{@price}: #{percentChange.toFixed(2)}%"
        
        percentChange >= options.takeProfit

init: ->
    debug "*********** Instance Initialised *************"
    @context.options =
        fee: _fee / 100
        currency: _currency
        maxOrders: _maxOrders
        tradeLimit: _currency / _maxOrders / 4
        takeProfit: _takeProfit
        timeout: _timeout
        sellOnStop: _sellOnStop

    setPlotOptions
        rsi:
            color: 'blue'
            secondary: true

handle: ->
    #debug "**********************************************"
    
    if !@storage.params
        @storage.params = _.clone(@context.options)

    if !@context.portfolio
        @context.portfolio = new Portfolio(@context.options)
        @context.portfolio.add(new Pair('kraken', 'xbt_eur', 1, 250))
        @context.portfolio.add(new Pair('kraken', 'eth_eur', 1, 250))
        @context.portfolio.add(new Pair('kraken', 'etc_eur', 1, 250))
        @context.portfolio.add(new Pair('kraken', 'xmr_eur', 1, 250))

    @context.portfolio.update(@portfolios, @data.instruments, @context.options)
    @context.portfolio.save(@storage)
    @storage.options = @context.options

onStop: ->
    debug "************* Instance Stopped ***************"

    if @context.portfolio and @context.options.sellOnStop
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

        @storage.params = _.clone(@context.options)
        @context.options = _.clone(@storage.options)
