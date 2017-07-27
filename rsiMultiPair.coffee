datasources = require 'datasources'
params = require 'params'
trading = require 'trading'
talib = require 'talib'

# primary datasource
# datasources.add 'kraken', 'xbt_eur', 1

# secondary datasources
datasources.add 'kraken', 'eth_eur', 1, 250
datasources.add 'kraken', 'etc_eur', 1, 250
datasources.add 'kraken', 'ltc_eur', 1, 250
datasources.add 'kraken', 'xmr_eur', 1, 250

# Params
_currency = params.add 'Currency Limit', 1000
_decimalPlaces = params.add 'Decimal Places', 4
_fee = params.add 'Order Fee (%)', 0.26
_maxOrders = params.add 'Max Orders/Pair', 5
_takeProfit = params.add 'Take Profit (%)', 2.5
_sellOnStop = params.add 'Sell On Stop', false

TradeStatus =
    BUY: 1
    FILLED: 2
    SELL : 3

# Classes
class Helpers
    @round: (number, roundTo = 8) ->
        Number(Math.round(number + 'e' + roundTo) + 'e-' + roundTo);
    @floatAddition: (numberA, numberB, presision = 16) ->
        pow = Math.pow(10, presision)
        ((numberA * pow) + (numberB * pow)) / pow
    @percentChange: (oldPrice, newPrice) ->
        ((newPrice - oldPrice) / oldPrice) * 100

class Indicators
    @rsi: (inReal, optInTimePeriod) ->
        talib.RSI
            inReal: inReal
            startIdx: 0
            endIdx: inReal.length - 1
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
            pair.report(portfolio, options)
            pair.stop(portfolio, options)

    update: (portfolios, instruments, options) ->
        @ticks++

        for pair in @pairs
            portfolio = portfolios[pair.market]
            pair.confirmOrders(portfolio, options)
            pair.update(portfolio, options)

            #if @ticks % 240 == 0
            #    pair.report(portfolio, options)
        #debug "***** RSI: #{_.map(@pairs, (pair) ->
        #    instrument = datasources.get(pair.market, pair.name, pair.interval)
        #    "#{instrument.asset()} #{pair.rsi.toFixed(2)}"
        #).join(', ')}"

class Pair
    constructor: (market, name, interval, size = 100) ->
        @profit = 0
        @count = 0
        @market = market
        @name = name
        @interval = interval
        @size = size
        @trades = []

    restore: (count = 0, profit = 0, trades) ->
        debug "*********** Pair #{@name} Restored *************"
        @count = count
        @profit = profit
        @trades = _.map trades, (trade) ->
            new Trade(trade)

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
        if options.sellOnStop
            instrument = datasources.get(@market, @name, @interval)
            _.each(@trades, (trade) ->
                @sell(portfolio, instrument, options, trade)
            , @)

    report: (portfolio, options) ->
        instrument = datasources.get(@market, @name, @interval)
        ticker = trading.getTicker instrument
        tradePrice = Helpers.round(ticker.sell * 0.9999, options.decimalPlaces)
        if @profit > 0
            info "EARNINGS #{instrument.asset().toUpperCase()}: #{@profit.toFixed(options.decimalPlaces)} #{instrument.curr()}"
        else
            warn "EARNINGS #{instrument.asset().toUpperCase()}: #{@profit.toFixed(options.decimalPlaces)} #{instrument.curr()}"
        _.each @trades, (trade) -> trade.report(instrument, tradePrice)

    confirmOrders: (portfolio, options) ->
        @trades = _.reject(@trades, (trade) ->
            if trade.status == TradeStatus.BUY and trade.buy
                order = trading.getOrder(trade.buy.orderId)
                debug "CHECK BUY ORDER: #{JSON.stringify(_.pick(order, ['id', 'side', 'amount', 'price', 'active', 'cancelled', 'filled']), null, '\t')}"
                if not order or order.filled
                    trade.status = TradeStatus.FILLED
                    options.currency -= (trade.buy.price * trade.buy.amount) * (1 + options.fee)
                    debug "CURRENCY: #{options.currency} PROFIT: #{@profit}"
                else if order.cancelled
                    return true
            else if trade.status == TradeStatus.SELL and trade.sell
                order = trading.getOrder(trade.sell.orderId)
                debug "CHECK SELL ORDER: #{JSON.stringify(_.pick(order, ['id', 'side', 'amount', 'price', 'active', 'cancelled', 'filled']), null, '\t')}"
                if not order or order.filled
                    options.currency += (trade.sell.price * trade.sell.amount) * (1 - options.fee)
                    @profit += ((trade.sell.price * trade.sell.amount) * (1 - options.fee)) - ((trade.buy.price * trade.buy.amount) * (1 + options.fee))
                    debug "CURRENCY: #{options.currency} PROFIT: #{@profit}"
                    return true
                else if order.cancelled
                    return true
            return false
        , @)

    update: (portfolio, options) ->
        instrument = datasources.get(@market, @name, @interval)
        price = instrument.price

        rsis = Indicators.rsi(instrument.close, 14)
        rsi = rsis.pop()
        rsiLast = rsis.pop()

        if rsi != @rsi
            @rsi = rsi

            #plot
            #    rsi: @rsi

            if rsiLast <= 30 and @rsi > 30 #and @trades.length < options.maxOrders
                # Buy
                @buy(portfolio, instrument, options)
            else if rsiLast >= 70 and @rsi < 70
                # Sell
                ticker = trading.getTicker instrument
                tradePrice = Helpers.round(ticker.sell * 0.9999, options.decimalPlaces)

                _.each(
                    _.filter(@trades, (trade) ->
                        trade.status == TradeStatus.FILLED and trade.takeProfit(instrument, tradePrice, options))
                    , (trade) -> @sell(portfolio, instrument, options, trade)
                , @)

    buy: (portfolio, instrument, options) ->
        tradeLimit = options.tradeLimit #(options.currency * 0.05) #options.tradeLimit
        limit = tradeLimit * (1 - options.fee)
        currency = portfolio.positions[instrument.base()]

        if options.currency > limit
            currency = portfolio.positions[instrument.base()]
            ticker = trading.getTicker instrument
            price = Helpers.round(ticker.buy * 1.0001, options.decimalPlaces)
            amount = Helpers.round(limit / price, options.decimalPlaces)

            debug "BUY #{amount} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{amount * price}"

            try
                order = trading.addOrder
                    instrument: instrument
                    side: 'buy'
                    type: 'limit'
                    amount: amount
                    price: price

                trade = new Trade
                    id: @count++

                trade.buyOrder(_.pick(order, ['id', 'side', 'amount', 'price', 'active', 'cancelled', 'filled']))
                debug "ORDER: #{JSON.stringify(trade.buy, null, '\t')}"

                if order.filled
                    options.currency -= (trade.buy.price * trade.buy.amount) * (1 + options.fee)
                    debug "CURRENCY: #{options.currency} PROFIT: #{@profit}"

                @trades.push(trade)
            catch err
                debug "CUR: #{options.currency}"
                debug "ERR: #{err}: #{currency.amount} #{limit}"

    sell: (portfolio, instrument, options, trade) ->
        asset = portfolio.positions[instrument.asset()]
        ticker = trading.getTicker instrument
        price = Helpers.round(ticker.sell * 0.9999, options.decimalPlaces)
        amount = if asset.amount < trade.buy.amount then asset.amount else trade.buy.amount

        debug "SELL #{amount} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{amount * price}"

        try
            order = trading.addOrder
                instrument: instrument
                side: 'sell'
                type: 'limit'
                amount: amount
                price: price

            trade.sellOrder(_.pick(order, ['id', 'side', 'amount', 'price', 'active', 'cancelled', 'filled']))
            debug "ORDER: #{JSON.stringify(trade.sell, null, '\t')}"

            if order.filled
                options.currency += (trade.sell.price * trade.sell.amount) * (1 - options.fee)
                @profit += ((trade.sell.price * trade.sell.amount) * (1 - options.fee)) - ((trade.buy.price * trade.buy.amount) * (1 + options.fee))
                debug "CURRENCY: #{options.currency} PROFIT: #{@profit}"
                _.remove(@trades, (item) -> item.id == trade.id)
        catch err
            debug "CUR: #{options.currency}"
            debug "ERR: #{err}: #{asset.amount} #{amount}"

class Trade
    constructor: (trade) ->
        _.extend(@, trade)

    serialize: () ->
        JSON.parse(JSON.stringify(@))

    buyOrder: (order) ->
        @status = if order.id then TradeStatus.BUY else TradeStatus.FILLED
        @buy = order

    sellOrder: (order) ->
        @status = if order.id then TradeStatus.SELL else TradeStatus.FILLED
        @sell = order

    report: (instrument, price) ->
        percentChange = Helpers.percentChange(@buy.price, price)
        debug "#{instrument.asset()} @ #{@buy.price}: #{percentChange.toFixed(2)}%"

    takeProfit: (instrument, price, options) ->
        percentChange = Helpers.percentChange(@buy.price, price)

        if percentChange >= options.takeProfit
            info "#{instrument.asset()} @ #{@buy.price}: #{percentChange.toFixed(2)}%"
        else
            debug "#{instrument.asset()} @ #{@buy.price}: #{percentChange.toFixed(2)}%"

        percentChange >= options.takeProfit

init: ->
    debug "*********** Instance Initialised *************"
    @context.options =
        fee: _fee / 100
        currency: _currency
        decimalPlaces: _decimalPlaces
        maxOrders: _maxOrders
        tradeLimit: _currency / _maxOrders / 4
        takeProfit: _takeProfit
        sellOnStop: _sellOnStop

    setPlotOptions
        rsi:
            color: 'blue'
            secondary: true

handle: ->
    if !@storage.params
        @storage.params = _.clone(@context.options)

    if !@context.portfolio
        @context.portfolio = new Portfolio(@context.options)
        @context.portfolio.add(new Pair('kraken', 'xbt_eur', 1, 250))
        @context.portfolio.add(new Pair('kraken', 'eth_eur', 1, 250))
        @context.portfolio.add(new Pair('kraken', 'etc_eur', 1, 250))
        @context.portfolio.add(new Pair('kraken', 'ltc_eur', 1, 250))
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
