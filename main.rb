require 'bundler'

Bundler.require

require 'uri'
require 'net/http'
require 'time'
require 'jwt'
require 'json'
require 'pry'
require 'dotenv/load'
require 'line/bot'

BASE_URL = "https://api.quoine.com"
PRODUCT_ID = 5 # BTCJPY
RECORD_LIMIT = 100
LEVERAGE_LEVEL = 25

class Execution
  attr_reader :id, :quantity, :price, :taker_side, :created_at

  def initialize(model)
    @id = model['id']
    @quantity = model['quantity']
    @price = model['price']
    @taker_side = model['taker_side']
    @created_at = Time.at(model['created_at'].to_i)
  end
end

class Order
  attr_reader :id, :order_type, :quantity, :disc_quantity, :iceberg_total_quantity,
    :side, :filled_quantity, :price, :created_at, :updated_at, :status,
    :leverage_level, :source_exchange, :product_id, :product_code, :funding_currency,
    :currency_pair_code

  def initialize(model)
    @id = model['id']
    @status = model['status']
    @created_at = model['created_at']
    @updated_at = model['updated_at']
  end
end

class Trade
  attr_reader :id, :pnl, :updated_at, :created_at

  def initialize(model)
    @id = model['id']
    @pnl = model['pnl']
    @created_at = model['created_at']
    @updated_at = model['updated_at']
  end
end

class QuoineAPI
  def self.get_executions_by_timestamp(timestamp)
    STDERR.puts "Quoine API: GET /executions?timestamp=#{timestamp}"

    response = Net::HTTP.get(URI.parse("#{BASE_URL}/executions?product_id=#{PRODUCT_ID}&timestamp=#{timestamp}"))

    hash = JSON.parse(response)
    hash.map { |model| Execution.new(model) }
  end

  def self.get_orders(status: :live)
    STDERR.puts "Quoine API: GET /orders?status=#{status}"

    path = "/orders?status=#{status}"
    response = request_with_authentication(Net::HTTP::Get, path)

    hash = JSON.parse(response)
    hash['models'].map { |model| Order.new(model) }
  end

  def self.get_order(id)
    STDERR.puts "Quoine API: GET /orders/#{id}"

    path = "/orders/#{id}"
    response = request_with_authentication(Net::HTTP::Get, path)

    Order.new(JSON.parse(response))
  end

  def self.create_order(side:, quantity:, price:)
    STDERR.puts "Quoine API: POST /orders?side=#{side}&quantity=#{quantity}&price=#{price}"

    path = "/orders?product_id=#{PRODUCT_ID}"
    response = request_with_authentication(Net::HTTP::Post, path, {
      order_type: 'limit',
      product_id: PRODUCT_ID,
      side: side,
      quantity: quantity,
      price: price,
      leverage_level: LEVERAGE_LEVEL,
      funding_currency: 'JPY'
    })

    Order.new(JSON.parse(response))
  end

  def self.cancel_order(id)
    STDERR.puts "Quoine API: PUT /orders/#{id}/cancel"

    path = "/orders/#{id}/cancel"
    response = request_with_authentication(Net::HTTP::Put, path)

    Order.new(JSON.parse(response))
  end

  def self.get_trades(status: :open)
    STDERR.puts "Quoine API: GET /trades?status=#{status}"

    path = "/trades?status=#{status}"
    response = request_with_authentication(Net::HTTP::Get, path)

    hash = JSON.parse(response)
    hash['models'].map { |model| Trade.new(model) }
  end

  def self.close_trade(id)
    STDERR.puts "Quoine API: PUT /trades/#{id}/close"

    path = "/trades/#{id}/close"
    response = request_with_authentication(Net::HTTP::Put, path)

    Trade.new(JSON.parse(response))
  end

  def self.request_with_authentication(http_request, path, body = "")
    uri = URI.parse(BASE_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    token_id = ENV['QUOINE_TOKEN_ID']
    user_secret = ENV['QUOINE_TOKEN_SECRET']

    auth_payload = {
      path: path,
      nonce: DateTime.now.strftime('%Q'),
      token_id: token_id
    }

    signature = JWT.encode(auth_payload, user_secret, 'HS256')

    request = http_request.new(path)
    request.add_field('X-Quoine-API-Version', '2')
    request.add_field('X-Quoine-Auth', signature)
    request.add_field('Content-Type', 'application/json')
    request.body = (body.is_a?(String) ? body : body.to_json)

    response = http.request(request)

    # response.code

    response.body
  end
end

class LineAPI
  @client ||= Line::Bot::Client.new do |config|
    config.channel_secret = ENV['LINE_CHANNEL_SECRET']
    config.channel_token = ENV['LINE_CHANNEL_TOKEN']
  end

  def self.report_trade(trade)
    @client.push_message(ENV['LINE_USER_ID'], {
       type: 'text',
       text: "#{Time.now}: A trade was closed with #{trade.pnl} pnl."
     })
  end

  def self.send_alert(text)
    @client.push_message(ENV['LINE_USER_ID'], { type: 'text', text: text })
  end
end

def main
  all_trades = []
  locked_untill = Time.now - 1

  loop do
    current_time = Time.now

    if locked_untill > Time.now
      sleep(locked_untill - Time.now)
      next
    end

    executions = QuoineAPI.get_executions_by_timestamp(current_time.to_i - 60)
    prices = executions.map(&:price)

    order_price_min = prices.min * 0.99
    order_price_max = prices.max * 1.01

    QuoineAPI.create_order(side: 'buy',  quantity: 0.01, price: order_price_min)
    QuoineAPI.create_order(side: 'sell', quantity: 0.01, price: order_price_max)

    sleep(60)

    QuoineAPI.get_orders.each do |order|
      QuoineAPI.cancel_order(order.id)
    end

    QuoineAPI.get_trades.each do |trade|
      all_trades << trade
      will_close_at = trade.updated_at + 60

      Thread.new do
        sleep(will_close_at - Time.now)

        trade = QuoineAPI.close_trade(trade.id)

        LineAPI.report_trade(trade)

        # Lock 10 minitues to avoid the great slump.
        if trade.pnl < 0
          locked_untill = Time.now + 600
        end
      end
    end
  end
rescue Interrupt
  puts "Interrupted."
rescue => e
  LineAPI.send_alert(e.message)

  raise e
ensure
  puts 'Cancelling all orders ...'

  QuoineAPI.get_orders.each do |order|
    QuoineAPI.cancel_order(order.id)
  end

  puts 'Closing all trades ...'

  QuoineAPI.get_trades.each do |trade|
    QuoineAPI.close_trade(trade.id)
  end
end

main
