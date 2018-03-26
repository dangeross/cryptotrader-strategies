datasources = require 'datasources'
params = require 'params'
trading = require 'trading'
talib = require 'talib'

_market = 'poloniex'
_assets = ['btc', 'etc', 'ltc', 'xmr']
_base = _assets[0];
_currency = 'usdt'
_interval = 1

# secondary datasources
for asset in _assets
    datasources.add _market, "#{asset}_#{_currency}", _interval, 500

# Params
_addTrade = params.add 'Add Manual Trade', '{}'
_currencyLimit = params.add 'Currency Limit', 100000
_iceTrades = params.add 'Ice Trades', 1
_fee = params.add 'Trade Fee (%)', 0.15
_stopLossMax = params.add 'Stop Loss Max (%)', -3
_sellOnStop = params.add 'Sell On Stop', false
_volumePrecision = params.add 'Volume Precision', 6
_pairParams = {}
for asset in _assets
    _pairParams[asset] =
        trade: params.addOptions "#{asset.toUpperCase()} Trading", ['Both', 'Buy', 'Sell', 'None'], if asset is _assets[0] then 'Both' else 'None'

TradeStatus =
    ACTIVE: 1
    IDLE: 2
    UNCONFIRMED: 3
    
MarketConditions =
    SUPERBEAR: "SUPERBEAR"
    BEAR: "BEAR"
    BORING: "BORING"
    BULL: "BULL"
    SUPERBULL: "SUPERBULL"
    
_marketParams = {}
_marketParams.SUPERBEAR =
    buyLimit: params.add 'SUPERBEAR Buy Limit', 10
    dynamicSellCalc: params.add 'SUPERBEAR Dynamic Sell Calc', false
    stopLoss: params.add 'SUPERBEAR Stop Loss (%)', -2
    sellOnly: params.add 'SUPERBEAR Sell Only', true
    sellTrigger: params.add 'SUPERBEAR Sell Trigger (%)', 1
_marketParams.BEAR =
    buyLimit: params.add 'BEAR Buy Limit', 10
    dynamicSellCalc: params.add 'BEAR Dynamic Sell Calc', false
    stopLoss: params.add 'BEAR Stop Loss (%)', 0
    sellOnly: params.add 'BEAR Sell Only', true
    sellTrigger: params.add 'BEAR Sell Trigger (%)', 2
_marketParams.BORING =
    buyLimit: params.add 'BORING Buy Limit', 10
    dynamicSellCalc: params.add 'BORING Dynamic Sell Calc', false
    stopLoss: params.add 'BORING Stop Loss (%)', 0
    sellOnly: params.add 'BORING Sell Only', false
    sellTrigger: params.add 'BORING Sell Trigger (%)', 4
_marketParams.BULL =
    buyLimit: params.add 'BULL Buy Limit', 10
    dynamicSellCalc: params.add 'BULL Dynamic Sell Calc', true
    stopLoss: params.add 'BULL Stop Loss (%)', 0
    sellOnly: params.add 'BULL Sell Only', true
    sellTrigger: params.add 'BULL Sell Trigger (%)', 4
_marketParams.SUPERBULL =
    buyLimit: params.add 'SUPERBULL Buy Limit', 10
    dynamicSellCalc: params.add 'SUPERBULL Dynamic Sell Calc', true
    stopLoss: params.add 'SUPERBULL Stop Loss (%)', 0
    sellOnly: params.add 'SUPERBULL Sell Only', true
    sellTrigger: params.add 'SUPERBULL Sell Trigger (%)', 4

# Classes
class Helpers
    @last: (inReal, offset = 0) ->
        inReal[inReal.length - 1 - offset]
    @round: (number, roundTo = 8) ->
        Number(Math.round(number + 'e' + roundTo) + 'e-' + roundTo)
    @toFixed: (number, roundTo = 2) ->
        if number then number.toFixed(roundTo) else number
    @floatAddition: (numberA, numberB, presision = 16) ->
        pow = Math.pow(10, presision)
        ((numberA * pow) + (numberB * pow)) / pow
    @percentChange: (oldPrice, newPrice) ->
        ((newPrice - oldPrice) / oldPrice) * 100
    @average: (array) ->
        _.reduce(array, (total, value) -> 
            total + (value || 0)
        , 0) / array.length

class Indicators
    @rsi: (inReal, optInTimePeriod) ->
        talib.RSI
            inReal: inReal
            startIdx: 0
            endIdx: inReal.length - 1
            optInTimePeriod: optInTimePeriod
    @trend: (inReal, optInTimePeriod) ->
        Helpers.percentChange(Helpers.average(inReal.slice(inReal.length - 1 - optInTimePeriod)), inReal[inReal.length - 1])

class Market
    constructor: (options) ->
        @ticks = 0
        @pairs = []
        @options = options
        @options.condition ?= MarketConditions.BORING

    add: (pair) ->
        primary = (@pairs.length == 0)
        @pairs.push(pair)

    addManualTrade: (tradeString, options) ->
        tradeJson = Trade.lengthen(JSON.parse(tradeString))
        if tradeJson and tradeJson.asset
            pair = _.find(@pairs, {asset: tradeJson.asset})
            if pair
                trade = _.find(pair.trades, {id: tradeJson.id})
                if tradeJson.side == 'buy'
                    if trade
                        if trade.status == TradeStatus.UNCONFIRMED and tradeJson.confirm
                            trade.status = TradeStatus.IDLE
                            options.currency -= (trade.buy.price * trade.buy.amount) * (1 + trade.buy.fee)
                            debug "CURRENCY: #{options.currency}"
                        else if not tradeJson.confirm
                            _.remove(pair.trades, (item) -> item.id == trade.id)
                    else if not trade and tradeJson.confirm
                        trade = new Trade
                            id: pair.count++
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
        storage.pairs = _.map @pairs, (pair) -> pair.save()

    stop: (portfolios, instruments, options) ->
        for pair in @pairs
            portfolio = portfolios[pair.market]
            pair.report(portfolio, options)
            pair.stop(portfolio, options)

    reserved: () ->
        _.reduce(@pairs, (reserve, pair) ->
            _.reduce(pair.trades, (total, trade) -> 
                total + if trade.status == TradeStatus.ACTIVE and trade.buy and not trade.sell then (trade.buy.price * trade.buy.amount) * (1 + trade.buy.fee) else 0
            , reserve)
        , 0)
    
    update: (portfolios, instruments, options) ->
        @ticks++
        
        basePair = @pairs[0]
        baseInstrument = datasources.get(basePair.market, basePair.name, basePair.interval)
        
        @trend =
            base: 
                m30: Indicators.trend(baseInstrument.close, 30)
                h4: Indicators.trend(baseInstrument.close, 240)
                h8: Indicators.trend(baseInstrument.close, 480)
            all:
                m30: (_.reduce(@pairs, (total, pair) ->
                    inst = datasources.get(pair.market, pair.name, pair.interval)
                    total + Indicators.trend(inst.close, 30)
                , 0) / @pairs.length)
                h4: (_.reduce(@pairs, (total, pair) ->
                    inst = datasources.get(pair.market, pair.name, pair.interval)
                    total + Indicators.trend(inst.close, 240)
                , 0) / @pairs.length)
                h8: (_.reduce(@pairs, (total, pair) ->
                    inst = datasources.get(pair.market, pair.name, pair.interval)
                    total + Indicators.trend(inst.close, 480)
                , 0) / @pairs.length)
                
        condition = @options.condition
                
        if (@trend.base.h8 < 0)
            condition = MarketConditions.SUPERBEAR
        else if (@trend.base.h4 < 0 or @trend.base.m30 < -1)
            condition = MarketConditions.BEAR
        else if (@trend.base.h8 > 0.5 and @trend.base.h4 > 0.5 and @trend.base.h4 < 2 and @trend.base.h8 < 2)
            condition = MarketConditions.BORING
        else if (@trend.base.h4 > 4)
            condition = MarketConditions.SUPERBULL
        else if (@trend.base.h8 > 3)
            condition = MarketConditions.BULL
        
        if (@options.condition != condition)
            info "Market changed from #{@options.condition} to #{condition}"
            @options.condition = condition
            toPlot = {}
            toPlot[condition] = baseInstrument.price
            plotMark toPlot
                
        plot
            #a30m: @trend.all.m30
            #a4h: @trend.all.h4
            #a8h: @trend.all.h8
            b30m: @trend.base.m30
            b4h: @trend.base.h4
            b8h: @trend.base.h8

        for pair in @pairs
            portfolio = portfolios[pair.market]
            pair.confirmOrders(portfolio, options)
            pair.update(portfolio, @, options)

            if @ticks % 240 == 0
                pair.report(portfolio, options)
        #debug "***** RSI: #{_.map(@pairs, (pair) ->
        #    instrument = datasources.get(pair.market, pair.name, pair.interval)
        #    "#{instrument.asset()} #{Helpers.toFixed(pair.rsi)}"
        #).join(', ')}"

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
            trade.id ?= @count++
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
            price = Helpers.round(ticker.sell * 0.9999, options.precision)

            _.each(@trades, (trade) ->
                @sell(portfolio, instrument, options, trade, price)
            , @)

    report: (portfolio, options) ->
        instrument = datasources.get(@market, @name, @interval)
        marketOptions = options.market[options.condition]
        ticker = trading.getTicker instrument

        if ticker
            tradePrice = Helpers.round(ticker.sell * 0.9999, options.precision)
            bhAmount = (_currencyLimit / _assets.length) / @bhPrice
            bhProfit = ((tradePrice * bhAmount) * (1 - options.fee)) - ((@bhPrice * bhAmount) * (1 + options.fee))
            currentProfit = _.reduce(@trades, (total, trade) ->
                Helpers.floatAddition(total, trade.profit(options, tradePrice))
            , @profit)
            currentAsset = Helpers.round(_.reduce(@trades, (total, trade) ->
                Helpers.floatAddition(total, if trade.status is TradeStatus.IDLE then trade.buy.amount else 0)
            , 0), options.precision);
            
            dynamicSellTrigger = Helpers.percentChange(Helpers.last(instrument.close, 360), tradePrice) / 2
            sellTrigger = if marketOptions.dynamicSellCalc then Math.max(marketOptions.sellTrigger, dynamicSellTrigger) else marketOptions.sellTrigger

            if @profit >= 0
                info "EARNINGS #{instrument.asset()}: #{Helpers.toFixed(@profit, options.precision)} #{instrument.curr()}/INC TRADES (#{currentAsset} #{instrument.asset()}) #{Helpers.toFixed(currentProfit, options.precision)} #{instrument.curr()} (B/H: #{Helpers.toFixed(bhProfit, options.precision)} #{instrument.curr()})"
            else
                warn "EARNINGS #{instrument.asset()}: #{Helpers.toFixed(@profit, options.precision)} #{instrument.curr()}/INC TRADES (#{currentAsset} #{instrument.asset()}) #{Helpers.toFixed(currentProfit, options.precision)} #{instrument.curr()} (B/H: #{Helpers.toFixed(bhProfit, options.precision)} #{instrument.curr()})"
            _.each @trades, (trade) -> trade.report(instrument, tradePrice, sellTrigger, options)

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
                else if trade.sell.at < (now - 180000)
                    warn "CANCEL ORDER: #{@asset} [#{trade.id}] #{trade.sell.amount} @ #{trade.sell.price}"
                    trade.status = TradeStatus.IDLE
                    delete trade.sell
                    trading.cancelOrder(order)
            else if trade.status == TradeStatus.ACTIVE and trade.buy
                order = trading.getOrder(trade.buy.id)
                debug "CHECK BUY ORDER: [#{trade.id}] #{JSON.stringify(_.pick(order, ['id', 'side', 'amount', 'price', 'active', 'cancelled', 'filled']), null, '\t')}"
                if not order or order.filled
                    trade.status = TradeStatus.IDLE
                    options.currency -= (trade.buy.price * trade.buy.amount) * (1 + trade.buy.fee)
                    debug "CURRENCY: #{options.currency} PROFIT: #{@profit}"
                else if order.cancelled
                    return true
                else if trade.buy.at < (now - 180000)
                    warn "CANCEL ORDER: #{@asset} [#{trade.id}] #{trade.buy.amount} @ #{trade.buy.price}"
                    trading.cancelOrder(order)
                    return true
            return false
        , @)

    update: (portfolio, market, options) ->
        instrument = datasources.get(@market, @name, @interval)
        pairOptions = options.pair[@asset]
        marketOptions = options.market[options.condition]
        price = instrument.price
        @bhPrice ?= price

        rsis = Indicators.rsi(instrument.close, 14)
        rsi = rsis.pop()
        rsiLast = rsis.pop()
        
        if instrument.asset() == _base
            plot
                rsi: if rsi <= 30 then -1 else if rsi >= 70 then 1 else 0

        if not @rsi or rsi != @rsi
            @rsi = rsi

            if (pairOptions.trade == 'Both' or pairOptions.trade == 'Buy') and (rsiLast <= 30 and @rsi > 30)
                if not marketOptions.sellOnly
                    # Buy
                    for count in [1..options.iceTrades]
                        @buy(portfolio, market, instrument, options)
                else
                    warn "AVOIDING BUY: #{options.condition} SELL-ONLY MODE"
                    plotMark
                        "AVOID": instrument.price
            else if (pairOptions.trade == 'Both' or pairOptions.trade == 'Sell') and ((rsiLast >= 70 and @rsi < 70) or marketOptions.stopLoss != 0)
                # Sell
                ticker = trading.getTicker instrument

                if ticker
                    price = Helpers.round(ticker.sell * 0.9999, options.precision)
                    dynamicSellTrigger = Helpers.percentChange(Helpers.last(instrument.close, 360), price) / 2
                    sellTrigger = if marketOptions.dynamicSellCalc then Math.max(marketOptions.sellTrigger, dynamicSellTrigger) else marketOptions.sellTrigger
                    
                    @trades = _.reject(@trades, (trade) ->
                        if trade.status == TradeStatus.IDLE
                            percentChange = trade.percentChange(price)
                            profit = trade.profit(options, price)
                            
                            if rsiLast >= 70 and @rsi < 70 and percentChange >= sellTrigger
                                info "#{instrument.asset()} [#{trade.id}] #{trade.buy.amount} @ #{trade.buy.price}: #{Helpers.toFixed(profit, options.precision)} #{instrument.curr()} (#{Helpers.toFixed(sellTrigger)}%/#{Helpers.toFixed(percentChange)}%)"
                                return @sell(portfolio, instrument, options, trade, price)
                            else if marketOptions.stopLoss != 0 and percentChange <= marketOptions.stopLoss and percentChange >= options.stopLossMax
                                warn "STOP-LOSS TRIGGERED: #{options.condition}"
                                warn "#{instrument.asset()} [#{trade.id}] #{trade.buy.amount} @ #{trade.buy.price}: #{Helpers.toFixed(profit, options.precision)} #{instrument.curr()} (#{Helpers.toFixed(marketOptions.stopLoss)}%/#{Helpers.toFixed(percentChange)}%)"
                                return @sell(portfolio, instrument, options, trade, price)
                            else if marketOptions.stopLoss == 0
                                debug "#{instrument.asset()} [#{trade.id}] #{trade.buy.amount} @ #{trade.buy.price}: #{Helpers.toFixed(profit, options.precision)} #{instrument.curr()} (#{Helpers.toFixed(sellTrigger)}%/#{Helpers.toFixed(percentChange)}%)"
                            return false
                    , @)

    buy: (portfolio, market, instrument, options) ->
        marketOptions = options.market[options.condition]
        limit = marketOptions.buyLimit * (1 - options.fee)
        currency = portfolio.positions[instrument.base()]
        reserved = market.reserved()
        availableCurrency = options.currency - reserved
        ticker = trading.getTicker instrument
        
        debug "RESERVED: #{reserved} AVAILABLE: #{availableCurrency}"

        if ticker and availableCurrency > limit
            price = Helpers.round(ticker.buy * (1 + (Math.random() * 0.0001)), options.precision)
            amount = Helpers.round(limit / price, options.precision)
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
                    co: true
                    as: instrument.asset()
                    si: 'buy'
                    am: amount
                    pr: price
                    fe: options.fee

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
                    return true
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
                    co: true
                    as: instrument.asset()
                    si: 'sell'
                    am: amount
                    pr: price
                    fe: options.fee
        else
            debug "AMOUNT MISMATCH: {asset.amount} #{amount}"
            return true

class Trade
    constructor: (trade) ->
        _.extend(@, trade)
        
    @shorten: (order) ->
        id: order.id
        co: order.confirm
        as: order.asset
        si: order.side
        am: order.amount
        pr: order.price
        fe: order.fee
        
    @lengthen: (order) ->
        id: order.id
        confirm: order.co
        asset: order.as
        side: order.si
        amount: order.am
        price: order.pr
        fee: order.fe

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

    report: (instrument, price, sellTrigger, options) ->
        percentChange = @percentChange(price)
        profit = @profit(options, price)

        if @status != TradeStatus.IDLE
            warn "#{instrument.asset()} [#{@id}] #{@buy.amount} @ #{@buy.price}: #{Helpers.toFixed(profit, options.precision)} #{instrument.curr()} (#{Helpers.toFixed(sellTrigger)}%/#{Helpers.toFixed(percentChange)}%)"
        else
            debug "#{instrument.asset()} [#{@id}] #{@buy.amount} @ #{@buy.price}: #{Helpers.toFixed(profit, options.precision)} #{instrument.curr()} (#{Helpers.toFixed(sellTrigger)}%/#{Helpers.toFixed(percentChange)}%)"

    profit: (options, price) ->
        ((price * @buy.amount) * (1 - options.fee)) - ((@buy.price * @buy.amount) * (1 + @buy.fee))
        
    percentChange: (price) ->
        Helpers.percentChange(@buy.price, price)
        
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
        iceTrades: _iceTrades
        pair: _pairParams
        market: _marketParams
        sellOnStop: _sellOnStop
        stopLossMax: _stopLossMax
        precision: _volumePrecision

    setPlotOptions
        'AVOID':
            color: 'orange'
        'SUPERBEAR':
            color: 'darkblue'
        'BEAR':
            color: 'dodgerblue'
        'BORING':
            color: 'grey'
        'BULL':
            color: 'aquamarine'
        'SUPERBULL':
            color: 'darkcyan'
        rsi:
            color: 'red'
            secondary: true
        b30m:
            secondary: true
        b4h:
            secondary: true
        b8h:
            secondary: true
        a30m:
            secondary: true
        a4h:
            secondary: true
        a8h:
            secondary: true

handle: ->
    Store.unpack(@storage)
    
    if !@storage.params
        @storage.params = _.cloneDeep(@context.options)

    if !@context.portfolio
        @context.portfolio = new Market(@context.options)
        for asset in _assets
            @context.portfolio.add(new Pair(_market, asset, _currency, _interval, 250))

    @context.portfolio.update(@portfolios, @data.instruments, @context.options)
    @context.portfolio.save(@storage)
    @storage.options = _.cloneDeep(@context.options)
    
    Store.pack(@storage)

onStop: ->
    debug "************* Instance Stopped ***************"

    if @context.portfolio
        @context.portfolio.stop(@portfolios, @data.instruments, @context.options)

onRestart: ->
    debug "************ Instance Restarted **************"
    Store.unpack(@storage)

    if @storage.pairs
        @context.portfolio = new Market(@context.options)
        @context.portfolio.restore(@portfolios, @context.options, @storage.pairs, _assets)

    if @storage.options
        debug "************* Options Restored ***************"
        _.each @context.options, (value, key) ->
            if key is 'currency'
                if @storage.params[key] != @context.options[key]
                    @storage.options[key] = @context.options[key]
            else
                @storage.options[key] = @context.options[key]
            debug "context.options.#{key}: #{if typeof @context.options[key] is 'object' then JSON.stringify(@context.options[key]) else @context.options[key]}"
            debug "storage.params.#{key}: #{if typeof @storage.params[key] is 'object' then JSON.stringify(@storage.params[key]) else @storage.params[key]}"
            debug "storage.options.#{key}: #{if typeof @storage.options[key] is 'object' then JSON.stringify(@storage.options[key]) else @storage.options[key]}"

        @storage.params = _.cloneDeep(@context.options)
        @context.options = _.cloneDeep(@storage.options)

    if @context.portfolio
        @context.portfolio.addManualTrade(_addTrade, @context.options)
        
    Store.pack(@storage)
