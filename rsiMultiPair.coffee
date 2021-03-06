datasources = require 'datasources'
params = require 'params'
trading = require 'trading'
talib = require 'talib'

_market = 'kraken'
_assets = ['xbt', 'eth', 'etc', 'ltc', 'xmr']
_currency = 'eur'
_interval = 1

# secondary datasources
for asset in _assets.slice(1)
    datasources.add _market, "#{asset}_#{_currency}", _interval, 250

# Params
_addTrade = params.add 'Add Manual Trade', '{}'
_currencyLimit = params.add 'Currency Limit', 1000
_tradeLimit = params.add 'Trade Limit', 75
_fee = params.add 'Trade Fee (%)', 0.26
_takeProfit = params.add 'Take Profit (%)', 2.5
_sellOnStop = params.add 'Sell On Stop', false
_volumePrecision = params.add 'Volume Precision', 4
_pairParams = {}
for asset in _assets
    _pairParams[asset] =
        trade: params.addOptions "#{asset.toUpperCase()} Trading", ['Both', 'Buy', 'Sell', 'None'], 'Both'
        precision: params.add "#{asset.toUpperCase()} Precision", 4

TradeStatus =
    ACTIVE: 1
    IDLE: 2
    UNCONFIRMED: 3

# Classes
class Helpers
    @round: (number, roundTo = 8) ->
        Number(Math.round(number + 'e' + roundTo) + 'e-' + roundTo)
    @toFixed: (number, roundTo = 2) ->
        if number then number.toFixed(roundTo) else number
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

    addManualTrade: (tradeString, options) ->
        tradeJson = JSON.parse(tradeString)
        if tradeJson and tradeJson.asset
            pair = _.find(@pairs, {asset: tradeJson.asset})
            if pair
                trade = _.find(pair.trades, {id: tradeJson.id})
                if tradeJson.side == 'buy'
                    if trade and trade.status == TradeStatus.UNCONFIRMED
                        if tradeJson.confirm
                            trade.status = TradeStatus.IDLE
                            options.currency -= (trade.buy.price * trade.buy.amount) * (1 + trade.buy.fee)
                            debug "CURRENCY: #{options.currency}"
                        else
                            _.remove(pair.trades, (item) -> item.id == trade.id)
                    else if not trade and tradeJson.confirm
                        trade = new Trade
                            id: tradeJson.id
                            status: TradeStatus.IDLE
                        trade.buy = tradeJson
                        options.currency -= (trade.buy.price * trade.buy.amount) * (1 + trade.buy.fee)
                        debug "CURRENCY: #{options.currency}"
                        pair.trades.push(trade)
                else if tradeJson.side == 'sell' and trade
                    if tradeJson.confirm
                        options.currency += (tradeJson.price * tradeJson.amount) * (1 - tradeJson.fee)
                        pair.profit += ((tradeJson.price * tradeJson.amount) * (1 - tradeJson.fee)) - ((trade.buy.price * trade.buy.amount) * (1 + trade.buy.fee))
                        debug "CURRENCY: #{options.currency} PROFIT: #{pair.profit}"
                        _.remove(pair.trades, (item) -> item.id == trade.id)
                    else
                        trade.status = TradeStatus.IDLE
                        delete trade.sell

    restore: (portfolios, options, pairs, assets) ->
        debug "************ Portfolio Restored **************"
        _.each(pairs, (pair) ->
            if _.some(assets, (asset) -> pair.asset == asset)
                restoredPair = new Pair(pair.market, pair.asset, pair.currency, pair.interval, pair.size)
                restoredPair.restore(pair)
                @add(restoredPair)

                portfolio = portfolios[pair.market]
                restoredPair.report(portfolio, options)
        , @)
        _.each(assets, (asset) ->
            if not _.some(@pairs, (pair) -> pair.asset == asset)
                debug "************* Pair #{@name} Added **************"
                @add(new Pair(_market, asset, _currency, _interval, 250))
        , @)

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

            if @ticks % 240 == 0
                pair.report(portfolio, options)
        debug "***** RSI: #{_.map(@pairs, (pair) ->
            instrument = datasources.get(pair.market, pair.name, pair.interval)
            "#{instrument.asset()} #{Helpers.toFixed(pair.rsi)}"
        ).join(', ')}"

class Pair
    constructor: (market, asset, currency, interval, size = 100) ->
        @profit = 0
        @count = 0
        @market = market
        @asset = asset
        @currency = currency
        @name = "#{asset}_#{currency}"
        @interval = interval
        @size = size
        @trades = []

    restore: (pair) ->
        debug "*********** Pair #{@name} Restored *************"
        @count = pair.count || 0
        @profit = pair.profit || 0
        @bhPrice = pair.bhPrice
        @trades = _.map(pair.trades || [], (trade) ->
            trade.id ?= ++@count
            new Trade(trade)
        , @)

    save: () ->
        count: @count
        market: @market
        asset: @asset
        currency: @currency
        name: @name
        interval: @interval
        size: @size
        profit: @profit
        bhPrice: @bhPrice
        trades: _.map @trades, (trade) ->
            trade.serialize()

    stop: (portfolio, options) ->
        instrument = datasources.get(@market, @name, @interval)
        pairOptions = options.pair[@asset]
        ticker = trading.getTicker instrument

        if ticker and options.sellOnStop
            price = Helpers.round(ticker.sell * 0.9999, pairOptions.precision)

            _.each(@trades, (trade) ->
                @sell(portfolio, instrument, options, trade, price)
            , @)

    report: (portfolio, options) ->
        instrument = datasources.get(@market, @name, @interval)
        pairOptions = options.pair[@asset]
        ticker = trading.getTicker instrument

        if ticker
            tradePrice = Helpers.round(ticker.sell * 0.9999, pairOptions.precision)
            bhAmount = (_currencyLimit / _assets.length) / @bhPrice
            bhProfit = ((tradePrice * bhAmount) * (1 - options.fee)) - ((@bhPrice * bhAmount) * (1 + options.fee))
            vestedProfit = _.reduce(@trades, (total, trade) ->
                total + trade.profit(options, tradePrice)
            , @profit)

            if @profit >= 0
                info "EARNINGS #{instrument.asset()}: #{Helpers.toFixed(@profit, pairOptions.precision)} #{instrument.curr()}/INC TRADES #{Helpers.toFixed(vestedProfit, pairOptions.precision)} #{instrument.curr()} (B/H: #{Helpers.toFixed(bhProfit, pairOptions.precision)} #{instrument.curr()})"
            else
                warn "EARNINGS #{instrument.asset()}: #{Helpers.toFixed(@profit, pairOptions.precision)} #{instrument.curr()}/INC TRADES #{Helpers.toFixed(vestedProfit, pairOptions.precision)} #{instrument.curr()} (B/H: #{Helpers.toFixed(bhProfit, pairOptions.precision)} #{instrument.curr()})"
            _.each @trades, (trade) -> trade.report(instrument, tradePrice, options)

    confirmOrders: (portfolio, options) ->
        now = new Date().getTime()
        @trades = _.reject(@trades, (trade) ->
            if trade.status == TradeStatus.ACTIVE and trade.sell
                order = trading.getOrder(trade.sell.id)
                debug "CHECK SELL ORDER: [#{trade.id}] #{JSON.stringify(_.pick(order, ['id', 'side', 'amount', 'price', 'active', 'cancelled', 'filled']), null, '\t')}"
                if not order or order.filled
                    options.currency += (trade.sell.price * trade.sell.amount) * (1 - trade.sell.fee)
                    @profit += ((trade.sell.price * trade.sell.amount) * (1 - trade.sell.fee)) - ((trade.buy.price * trade.buy.amount) * (1 + trade.buy.fee))
                    debug "CURRENCY: #{options.currency} PROFIT: #{@profit}"
                    return true
                else if order.cancelled
                    trade.status = TradeStatus.IDLE
                    delete trade.sell
                    return false
                else if trade.sell.at < (now - 900000)
                    warn "CANCEL ORDER: #{@asset} [#{trade.id}] #{trade.sell.amount} @ #{trade.sell.price}"
                    trade.status = TradeStatus.IDLE
                    delete trade.sell
                    trading.cancelOrder(order)
                    return false
            else if trade.status == TradeStatus.ACTIVE and trade.buy
                order = trading.getOrder(trade.buy.id)
                debug "CHECK BUY ORDER: [#{trade.id}] #{JSON.stringify(_.pick(order, ['id', 'side', 'amount', 'price', 'active', 'cancelled', 'filled']), null, '\t')}"
                if not order or order.filled
                    trade.status = TradeStatus.IDLE
                    options.currency -= (trade.buy.price * trade.buy.amount) * (1 + trade.buy.fee)
                    debug "CURRENCY: #{options.currency} PROFIT: #{@profit}"
                else if order.cancelled
                    return true
                else if trade.buy.at < (now - 900000)
                    warn "CANCEL ORDER: #{@asset} [#{trade.id}] #{trade.buy.amount} @ #{trade.buy.price}"
                    trading.cancelOrder(order)
                    return true
            return false
        , @)

    update: (portfolio, options) ->
        instrument = datasources.get(@market, @name, @interval)
        pairOptions = options.pair[@asset]
        price = instrument.price
        @bhPrice ?= price

        rsis = Indicators.rsi(instrument.close, 14)
        rsi = rsis.pop()
        rsiLast = rsis.pop()

        if not @rsi or rsi != @rsi
            @rsi = rsi

            if (pairOptions.trade == 'Both' or pairOptions.trade == 'Buy') and rsiLast <= 30 and @rsi > 30
                # Buy
                @buy(portfolio, instrument, options)
            else if (pairOptions.trade == 'Both' or pairOptions.trade == 'Sell') and rsiLast >= 70 and @rsi < 70
                # Sell
                ticker = trading.getTicker instrument

                if ticker
                    price = Helpers.round(ticker.sell * 0.9999, pairOptions.precision)

                    _.each(
                        _.filter(@trades, (trade) ->
                            trade.status == TradeStatus.IDLE and trade.takeProfit(instrument, price, options))
                        , (trade) -> @sell(portfolio, instrument, options, trade, price)
                    , @)

    buy: (portfolio, instrument, options) ->
        limit = options.tradeLimit * (1 - options.fee)
        currency = portfolio.positions[instrument.base()]
        pairOptions = options.pair[@asset]
        ticker = trading.getTicker instrument

        if ticker and options.currency > limit
            price = Helpers.round(ticker.buy * 1.0001, pairOptions.precision)
            amount = Helpers.round(limit / price, options.volumePrecision)
            debug "BUY #{instrument.asset()} #{amount} @ #{price}: #{amount * price} #{instrument.curr()}"

            trade = new Trade
                id: @count++

            try
                order = trading.addOrder
                    instrument: instrument
                    side: 'buy'
                    type: 'limit'
                    amount: amount
                    price: price

                trade.buyOrder(order, options)
                debug "ORDER: #{JSON.stringify(trade.buy, null, '\t')}"

                if order.filled
                    options.currency -= (trade.buy.price * trade.buy.amount) * (1 + trade.buy.fee)
                    debug "CURRENCY: #{options.currency} PROFIT: #{@profit}"

                @trades.push(trade)
            catch err
                if /timedout|future/gi.exec err
                    trade.buyOrder({
                        side: 'buy',
                        amount: amount,
                        price: price
                    }, options)
                    trade.status = TradeStatus.UNCONFIRMED
                    @trades.push(trade)
                sendEmail "BUY FAILED: #{err}: #{amount} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{amount * price}"
                debug "ERR: #{err}: #{currency.amount} #{options.currency}"
                warn JSON.stringify
                    id: trade.id
                    confirm: true
                    asset: instrument.asset()
                    side: 'buy'
                    amount: amount
                    price: price
                    fee: options.fee

    sell: (portfolio, instrument, options, trade, price) ->
        asset = portfolio.positions[instrument.asset()]
        amount = if asset.amount < trade.buy.amount then asset.amount else trade.buy.amount

        if amount > 0
            debug "SELL #{instrument.asset()} #{amount} @ #{price}: #{amount * price} #{instrument.curr()}"

            try
                order = trading.addOrder
                    instrument: instrument
                    side: 'sell'
                    type: 'limit'
                    amount: amount
                    price: price

                trade.sellOrder(order, options)
                debug "ORDER: #{JSON.stringify(trade.sell, null, '\t')}"

                if order.filled
                    options.currency += (trade.sell.price * trade.sell.amount) * (1 - trade.sell.fee)
                    @profit += ((trade.sell.price * trade.sell.amount) * (1 - trade.sell.fee)) - ((trade.buy.price * trade.buy.amount) * (1 + trade.buy.fee))
                    debug "CURRENCY: #{options.currency} PROFIT: #{@profit}"
                    _.remove(@trades, (item) -> item.id == trade.id)
            catch err
                if /timedout|future/gi.exec err
                    trade.sellOrder({
                        side: 'sell',
                        amount: amount,
                        price: price
                    }, options)
                    trade.status = TradeStatus.UNCONFIRMED
                sendEmail "SELL FAILED: #{err}: #{amount} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{amount * price}"
                debug "ERR: #{err}: #{asset.amount} #{options.currency}"
                warn JSON.stringify
                    id: trade.id
                    confirm: true
                    asset: instrument.asset()
                    side: 'sell'
                    amount: amount
                    price: price
                    fee: options.fee
        else
            debug "AMOUNT MISMATCH: {asset.amount} #{amount}"
            _.remove(@trades, (item) -> item.id == trade.id)

class Trade
    constructor: (trade) ->
        _.extend(@, trade)

    serialize: () ->
        JSON.parse(JSON.stringify(@))

    buyOrder: (order, options) ->
        @status = if order.id then TradeStatus.ACTIVE else TradeStatus.IDLE
        @buy = _.pick(order, ['id', 'side', 'amount', 'price'])
        @buy.at = new Date().getTime()
        @buy.fee = options.fee

    sellOrder: (order, options) ->
        @status = if order.id then TradeStatus.ACTIVE else TradeStatus.IDLE
        @sell = _.pick(order, ['id', 'side', 'amount', 'price'])
        @sell.at = new Date().getTime()
        @sell.fee = options.fee

    report: (instrument, price, options) ->
        pairOptions = options.pair[instrument.asset()]
        percentChange = Helpers.percentChange(@buy.price, price)
        profit = @profit(options, price)

        if @status != TradeStatus.IDLE
            warn "#{instrument.asset()} [#{@id}] #{@buy.amount} @ #{@buy.price}: #{Helpers.toFixed(profit, pairOptions.precision)} #{instrument.curr()} (#{Helpers.toFixed(percentChange)}%)"
        else
            debug "#{instrument.asset()} [#{@id}] #{@buy.amount} @ #{@buy.price}: #{Helpers.toFixed(profit, pairOptions.precision)} #{instrument.curr()} (#{Helpers.toFixed(percentChange)}%)"

    profit: (options, price) ->
        ((price * @buy.amount) * (1 - options.fee)) - ((@buy.price * @buy.amount) * (1 + @buy.fee))

    takeProfit: (instrument, price, options) ->
        pairOptions = options.pair[instrument.asset()]
        percentChange = Helpers.percentChange(@buy.price, price)
        profit = @profit(options, price)

        if percentChange >= options.takeProfit
            info "#{instrument.asset()} [#{@id}] #{@buy.amount} @ #{@buy.price}: #{Helpers.toFixed(profit, pairOptions.precision)} #{instrument.curr()} (#{Helpers.toFixed(percentChange)}%)"
        else
            debug "#{instrument.asset()} [#{@id}] #{@buy.amount} @ #{@buy.price}: #{Helpers.toFixed(profit, pairOptions.precision)} #{instrument.curr()} (#{Helpers.toFixed(percentChange)}%)"

        percentChange >= options.takeProfit

init: ->
    debug "*********** Instance Initialised *************"
    @context.options =
        fee: _fee / 100
        currency: _currencyLimit
        tradeLimit: _tradeLimit
        takeProfit: _takeProfit
        pair: _pairParams
        sellOnStop: _sellOnStop
        volumePrecision: _volumePrecision

    setPlotOptions
        rsi:
            color: 'blue'
            secondary: true

handle: ->
    if !@storage.params
        @storage.params = _.clone(@context.options)

    if !@context.portfolio
        @context.portfolio = new Portfolio(@context.options)
        for asset in _assets
            @context.portfolio.add(new Pair(_market, asset, _currency, _interval, 250))

    @context.portfolio.update(@portfolios, @data.instruments, @context.options)
    @context.portfolio.save(@storage)
    @storage.options = @context.options

onStop: ->
    debug "************* Instance Stopped ***************"

    if @context.portfolio
        @context.portfolio.stop(@portfolios, @data.instruments, @context.options)

onRestart: ->
    debug "************ Instance Restarted **************"

    if @storage.pairs
        @context.portfolio = new Portfolio(@context.options)
        @context.portfolio.restore(@portfolios, @context.options, @storage.pairs, _assets)

    if @storage.options
        debug "************* Options Restored ***************"
        _.each @context.options, (value, key) ->
            if key == 'currency' and @storage.params.currency != value
                @storage.options.currency = value - (@storage.params.currency - @storage.options.currency)
            else if typeof @storage.options[key] is 'object'
                @storage.options[key] = value
            else if @storage.params[key] != value
                @storage.options[key] = value
            debug "options.#{key}: #{if typeof @storage.options[key] is 'object' then JSON.stringify(@storage.options[key]) else @storage.options[key]}"

        @storage.params = _.clone(@context.options)
        @context.options = _.clone(@storage.options)

    if @context.portfolio
        @context.portfolio.addManualTrade(_addTrade, @context.options)
