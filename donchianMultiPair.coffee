datasources = require 'datasources'
params = require 'params'
trading = require 'trading'
talib = require 'talib'

_market = 'bittrex'
_assets = ['btc', 'eth', 'neo']
_currency = 'usdt'
_interval = '1h'

# secondary datasources
for asset in _assets.slice(1)
    datasources.add _market, "#{asset}_#{_currency}", _interval, 250

# Params
_currencyLimit = params.add 'Currency Limit', 1000
_fee = params.add 'Trade Fee (%)', 0.25
_decimalPlaces = params.add 'Decimal Places', 4
_donchianPeriod = params.add 'Donchain Period', 23
_emaSmoothing = params.add 'EMA Smoothing', 2
_pairRestrictions = {}
for asset in _assets
    _pairRestrictions[asset] = params.addOptions "#{asset.toUpperCase()} Trading", ['Both', 'Buy', 'Sell', 'None'], 'Both'
_sellAtLoss = params.add 'Sell At Loss', true
_sellOnStop = params.add 'Sell On Stop', false
_addTrade = params.add 'Add Manual Trade', '{}'

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
    @maxSlice: (values, period) ->
        _.max(_.slice(values, values.length - period))
    @minSlice: (values, period) ->
        _.min(_.slice(values, values.length - period))

class Indicators
    @ema: (inReal, optInTimePeriod) ->
        talib.EMA
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

    count: () ->
        _.reject(@pairs, (pair) -> pair.trades.length == 0).length

    addManualTrade: (tradeString, options) ->
        tradeJson = JSON.parse(tradeString)
        if tradeJson and tradeJson.asset
            pair = _.find(@pairs, {asset: tradeJson.asset})
            if pair and tradeJson.side == "buy"
                trade = new Trade
                    id: pair.count++
                    status: TradeStatus.FILLED
                trade.buy = tradeJson
                options.currency -= (trade.buy.price * trade.buy.amount) * (1 + trade.buy.fee)
                debug "CURRENCY: #{options.currency}"
                pair.trades.push(trade)
            else if pair and tradeJson.side == "sell"
                trade = _.find(pair.trades, {id: tradeJson.id})
                if trade
                    options.currency += (tradeJson.price * tradeJson.amount) * (1 - tradeJson.fee)
                    pair.profit += ((tradeJson.price * tradeJson.amount) * (1 - tradeJson.fee)) - ((trade.buy.price * trade.buy.amount) * (1 + trade.buy.fee))
                    debug "CURRENCY: #{options.currency} PROFIT: #{pair.profit}"
                    _.remove(pair.trades, (item) -> item.id == trade.id)

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
        storage.pairs = _.map @pairs, (pair) -> pair.save()

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

        count = @count()

        if count > 0
            debug "**********************************************"

        limit = options.currency / (@pairs.length - count)

        for pair in @pairs
            pair.update(portfolio, options, limit)
            if @ticks % 24 == 0
                pair.report(portfolio, options)

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
        @trades = _.map pair.trades || [], (trade) ->
            new Trade(trade)

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
        if options.sellOnStop
            instrument = datasources.get(@market, @name, @interval)
            ticker = trading.getTicker instrument

            if ticker
                price = Helpers.round(ticker.sell * 0.9999, options.decimalPlaces)

                _.each(@trades, (trade) ->
                    @sell(portfolio, instrument, options, trade, price)
                , @)

    report: (portfolio, options) ->
        instrument = datasources.get(@market, @name, @interval)
        ticker = trading.getTicker instrument

        if ticker
            tradePrice = Helpers.round(ticker.sell * 0.9999, options.decimalPlaces)
            bhAmount = (_currencyLimit / _assets.length) / @bhPrice
            bhProfit = ((tradePrice * bhAmount) * (1 - options.fee)) - ((@bhPrice * bhAmount) * (1 + options.fee))
            vestedProfit = _.reduce(@trades, (total, trade) ->
                total + trade.profit(options, tradePrice)
            , @profit)

            if @profit >= 0
                info "EARNINGS #{instrument.asset()}: #{@profit.toFixed(options.decimalPlaces)} #{instrument.curr()}/INC TRADES #{vestedProfit.toFixed(options.decimalPlaces)} #{instrument.curr()} (B/H: #{bhProfit.toFixed(options.decimalPlaces)} #{instrument.curr()})"
            else
                warn "EARNINGS #{instrument.asset()}: #{@profit.toFixed(options.decimalPlaces)} #{instrument.curr()}/INC TRADES #{vestedProfit.toFixed(options.decimalPlaces)} #{instrument.curr()} (B/H: #{bhProfit.toFixed(options.decimalPlaces)} #{instrument.curr()})"

    confirmOrders: (portfolio, options) ->
        @trades = _.reject(@trades, (trade) ->
            if trade.status == TradeStatus.BUY and trade.buy
                order = trading.getOrder(trade.buy.id)
                debug "CHECK BUY ORDER: [#{trade.id}] #{JSON.stringify(_.pick(order, ['id', 'side', 'amount', 'price', 'active', 'cancelled', 'filled']), null, '\t')}"
                if not order or order.filled
                    trade.status = TradeStatus.FILLED
                    options.currency -= (trade.buy.price * trade.buy.amount) * (1 + trade.buy.fee)
                    debug "CURRENCY: #{options.currency} PROFIT: #{@profit}"
                else if order.cancelled
                    return true
                else
                    warn "CANCEL ORDER: #{@asset} [#{trade.id}] #{trade.buy.amount} @ #{trade.buy.price}"
                    trading.cancelOrder(order)
                    return true
            else if trade.status == TradeStatus.SELL and trade.sell
                order = trading.getOrder(trade.sell.id)
                debug "CHECK SELL ORDER: [#{trade.id}] #{JSON.stringify(_.pick(order, ['id', 'side', 'amount', 'price', 'active', 'cancelled', 'filled']), null, '\t')}"
                if not order or order.filled
                    options.currency += (trade.sell.price * trade.sell.amount) * (1 - trade.sell.fee)
                    @profit += ((trade.sell.price * trade.sell.amount) * (1 - trade.sell.fee)) - ((trade.buy.price * trade.buy.amount) * (1 + trade.buy.fee))
                    debug "CURRENCY: #{options.currency} PROFIT: #{@profit}"
                    return true
                else if order.cancelled
                    trade.status = TradeStatus.FILLED
                    return false
                else
                    trade.status = TradeStatus.FILLED
                    trading.cancelOrder(order)
                    warn "CANCEL ORDER: #{@asset} [#{trade.id}] #{trade.sell.amount} @ #{trade.sell.price}"
                    return false
            return false
        , @)

    update: (portfolio, options, limit) ->
        instrument = datasources.get(@market, @name, @interval)
        restriction = options.pairRestrictions[@asset]
        price = instrument.price
        @bhPrice ?= price

        ema = Indicators.ema(instrument.close, options.emaSmoothing)
        dMax = Helpers.maxSlice(ema, options.donchianPeriod)
        dMin = Helpers.minSlice(ema, options.donchianPeriod)

        _.each(@trades, (trade) -> trade.report(instrument, options, price, dMin))

        if (restriction == 'Both' or restriction == 'Buy') and @trades.length == 0 and price >= dMax
            @buy(portfolio, instrument, options, limit)
        else if (restriction == 'Both' or restriction == 'Sell') and @trades.length > 0 and price <= dMin
            _.each(@trades, (trade) ->
                if options.sellAtLoss or trade.profit(options, price) > 0
                    @sell(portfolio, instrument, options, trade)
            , @)

    buy: (portfolio, instrument, options, tradeLimit) ->
        limit = tradeLimit * (1 - options.fee)
        currency = portfolio.positions[instrument.base()]
        ticker = trading.getTicker instrument

        if ticker and options.currency > limit
            price = Helpers.round(ticker.buy * 1.0001, options.decimalPlaces)
            amount = Helpers.round(limit / price, options.decimalPlaces)

            debug "BUY #{instrument.asset()} #{amount} @ #{price}: #{amount * price} #{instrument.curr()}"

            try
                order = trading.addOrder
                    instrument: instrument
                    side: 'buy'
                    type: 'limit'
                    amount: amount
                    price: price

                trade = new Trade
                    id: @count++

                trade.buyOrder(order, options)
                debug "ORDER: #{JSON.stringify(trade.buy, null, '\t')}"

                if order.filled
                    options.currency -= (trade.buy.price * trade.buy.amount) * (1 + trade.buy.fee)
                    debug "CURRENCY: #{options.currency} PROFIT: #{@profit}"

                @trades.push(trade)
            catch err
                sendEmail "BUY FAILED: #{err}: #{amount} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{amount * price}"
                debug "ERR: #{err}: #{currency.amount} #{options.currency}"
                warn JSON.stringify
                    asset: instrument.asset()
                    side: 'buy'
                    amount: amount
                    price: price
                    fee: options.fee

    sell: (portfolio, instrument, options, trade) ->
        asset = portfolio.positions[instrument.asset()]
        amount = if asset.amount < trade.buy.amount then asset.amount else trade.buy.amount

        if amount > 0
            ticker = trading.getTicker instrument

            if ticker
                price = Helpers.round(ticker.sell * 0.9999, options.decimalPlaces)
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
                    sendEmail "SELL FAILED: #{err}: #{amount} #{instrument.asset()} @ #{price} #{instrument.curr()} = #{amount * price}"
                    debug "ERR: #{err}: #{asset.amount} #{options.currency}"
                    warn JSON.stringify
                        id: trade.id
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
        @status = if order.id then TradeStatus.BUY else TradeStatus.FILLED
        @buy = _.pick(order, ['id', 'side', 'amount', 'price'])
        @buy.at = new Date().getTime()
        @buy.fee = options.fee

    sellOrder: (order, options) ->
        @status = if order.id then TradeStatus.SELL else TradeStatus.FILLED
        @sell = _.pick(order, ['id', 'side', 'amount', 'price'])
        @sell.at = new Date().getTime()
        @sell.fee = options.fee

    profit: (options, price) ->
        ((price * @buy.amount) * (1 - options.fee)) - ((@buy.price * @buy.amount) * (1 + @buy.fee))

    report: (instrument, options, currentPrice, sellPrice) ->
        currentPercentChange = Helpers.percentChange(@buy.price, currentPrice)
        currentProfit = @profit(options, currentPrice)
        sellPercentChange = Helpers.percentChange(@buy.price, sellPrice)
        sellProfit = @profit(options, sellPrice)

        debug "#{instrument.asset()} #{@buy.amount} [#{@id}] #{currentProfit.toFixed(options.decimalPlaces)} #{instrument.curr()} (#{currentPercentChange.toFixed(2)}%): #{sellProfit.toFixed(options.decimalPlaces)} #{instrument.curr()} (#{sellPercentChange.toFixed(2)}%)"

class Store
    @trim: (storage) ->
        _.each(_.difference(_.keys(storage), ['params','options','pairs']), (key) ->
            delete storage[key]
        )

    @pack: (storage) ->
        @trim(storage)
        _.each(storage, (value, key) ->
            try
                storage[key] = if typeof value is not 'string' then JSON.stringify value else value
            catch err
                debug "#{typeof value}: #{err}"
        )
            
    @unpack: (storage) ->
        @trim(storage)
        _.each(storage, (value, key) ->
            try
                storage[key] = if typeof value is 'string' then JSON.parse value else value
            catch err
                debug "#{typeof value}: #{err}"
        )
        
init: ->
    debug "*********** Instance Initialised *************"
    @context.options =
        fee: _fee / 100
        currency: _currencyLimit
        decimalPlaces: _decimalPlaces
        donchianPeriod: _donchianPeriod
        emaSmoothing: _emaSmoothing
        pairRestrictions: _pairRestrictions
        sellAtLoss: _sellAtLoss
        sellOnStop: _sellOnStop

handle: ->
    Store.unpack(@storage)
    
    if !@storage.params
        @storage.params = _.cloneDeep(@context.options)

    if !@context.portfolio
        @context.portfolio = new Portfolio(@context.options)
        for asset in _assets
            @context.portfolio.add(new Pair(_market, asset, _currency, _interval, 250))

    @context.portfolio.update(@portfolios, @data.instruments, @context.options)
    @context.portfolio.save(@storage)
    @storage.options = @context.options
    
    Store.pack(@storage)

onStop: ->
    debug "************* Instance Stopped ***************"

    if @context.portfolio
        @context.portfolio.stop(@portfolios, @data.instruments, @context.options)

onRestart: ->
    debug "************ Instance Restarted **************"
    Store.unpack(@storage)

    if @storage.pairs
        @context.portfolio = new Portfolio(@context.options)
        @context.portfolio.restore(@portfolios, @context.options, @storage.pairs, _assets)

    if @storage.options
        debug "************* Options Restored ***************"
        _.each @context.options, (value, key) ->
            if typeof @storage.options[key] is 'object'
                @storage.options[key] = @context.options[key]
            else if @storage.params[key] != @context.options[key]
                @storage.options[key] = @context.options[key]
            debug "context.options.#{key}: #{if typeof @context.options[key] is 'object' then JSON.stringify(@context.options[key]) else @context.options[key]}"
            debug "storage.params.#{key}: #{if typeof @storage.params[key] is 'object' then JSON.stringify(@storage.params[key]) else @storage.params[key]}"
            debug "storage.options.#{key}: #{if typeof @storage.options[key] is 'object' then JSON.stringify(@storage.options[key]) else @storage.options[key]}"

        @storage.params = _.cloneDeep(@context.options)
        @context.options = _.cloneDeep(@storage.options)

    if @context.portfolio
        @context.portfolio.addManualTrade(_addTrade, @context.options)
        
    Store.pack(@storage)
