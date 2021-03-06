require 'thread'
require 'ib/socket'
require 'ib/logger'
require 'ib/messages'

module IB
  # Encapsulates API connection to TWS or Gateway
  class Connection

    # Please note, we are realizing only the most current TWS protocol versions,
    # thus improving performance at the expense of backwards compatibility.
    # Older protocol versions support can be found in older gem versions.

    DEFAULT_OPTIONS = {:host =>'127.0.0.1',
                       :port => '4001', # IB Gateway connection (default)
                       #:port => '7496', # TWS connection
                       :connect => true, # Connect at initialization
                       :reader => true, # Start a separate reader Thread
                       :received => true, # Keep all received messages in a @received Hash
                       :logger => nil,
                       :client_id => nil, # Will be randomly assigned
                       :client_version => IB::Messages::CLIENT_VERSION,
                       :server_version => IB::Messages::SERVER_VERSION
                       }

    # Singleton to make active Connection universally accessible as IB::Connection.current
    class << self
      attr_accessor :current
    end

    attr_accessor :options, #  Connection options
      :socket, #   Socket to IB server (TWS or Gateway)
      :reader, # Reader thread
      :client_version,
      :server_version,
      :remote_connect_time,
      :local_connect_time,
      :client_id, # Client id of this Connection (as seen bu IB server)
      :next_local_id # Next valid order id

    alias next_order_id next_local_id
    alias next_order_id= next_local_id=

    def initialize opts = {}
      @options = DEFAULT_OPTIONS.merge(opts)

      # A couple of locks to avoid race conditions in JRuby
      @subscribe_lock = Mutex.new
      @receive_lock = Mutex.new

      self.default_logger = options[:logger] if options[:logger]
      @connected = false
      self.next_local_id = nil

      connect if options[:connect]
      Connection.current = self
    end

    ### Working with connection

    def connect
      error "Already connected!" if connected?

      # TWS always sends NextValidId message at connect - save this id
      self.subscribe(:NextValidId) do |msg|
        self.next_local_id = msg.local_id
        log.info "Got next valid order id: #{next_local_id}."
      end

      @socket = IBSocket.open(options[:host], options[:port])

      # Secret handshake
      @client_version = options[:client_version]
      socket.write_data @client_version
      @server_version = socket.read_int
      if @server_version < options[:server_version]
        error "Server version #{@server_version}, #{options[:server_version]} required."
      end
      @remote_connect_time = socket.read_string
      @local_connect_time = Time.now

      # Sending (arbitrary) client ID to identify subsequent communications.
      # The client with a client_id of 0 can manage the TWS-owned open orders.
      # Other clients can only manage their own open orders.
      @client_id = options[:client_id] || random_id
      socket.write_data @client_id

      @connected = true
      log.info "Connected to server, ver: #{@server_version}, connection time: " +
        "#{@local_connect_time} local, " +
        "#{@remote_connect_time} remote."

      start_reader if options[:reader] # Allows reconnect
    end

    alias open connect # Legacy alias

    def disconnect
      if reader_running?
        @reader_running = false
        @reader.join
      end
      if connected?
        socket.close
        @connected = false
      end
    end

    alias close disconnect # Legacy alias

    def connected?
      @connected
    end

    ### Working with message subscribers

    # Subscribe Proc or block to specific type(s) of incoming message events.
    # Listener will be called later with received message instance as its argument.
    # Returns subscriber id to allow unsubscribing
    def subscribe *args, &block
      @subscribe_lock.synchronize do
        subscriber = args.last.respond_to?(:call) ? args.pop : block
        id = random_id

        error "Need subscriber proc or block", :args unless subscriber.is_a? Proc

        IB::Messages::Incoming::AbstractMessage.resolve_message_classes(args).each do |message_class|
            # TODO: Fix: RuntimeError: can't add a new key into hash during iteration
            subscribers[message_class][id] = subscriber
        end
        id
      end
    end

    # Remove all subscribers with specific subscriber id (TODO: multiple ids)
    def unsubscribe *ids
      @subscribe_lock.synchronize do
        removed = []
        ids.each do |id|
          removed_at_id = subscribers.map { |_, subscribers| subscribers.delete id }.compact
          error "No subscribers with id #{id}" if removed_at_id.empty?
          removed << removed_at_id
        end
        removed.flatten
      end
    end

    # Message subscribers. Key is the message class to listen for.
    # Value is a Hash of subscriber Procs, keyed by their subscription id.
    # All subscriber Procs will be called with the message instance
    # as an argument when a message of that type is received.
    def subscribers
      @subscribers ||= Hash.new { |hash, subs| hash[subs] = Hash.new }
    end

    ### Working with received messages Hash

    # Clear received messages Hash
    def clear_received *message_types
      @receive_lock.synchronize do
        if message_types.empty?
          received.each { |message_type, container| container.clear }
        else
          message_types.each { |message_type| received[message_type].clear }
        end
      end
    end

    # Hash of received messages, keyed by message type
    def received
      @received ||= Hash.new { |hash, message_type| hash[message_type] = Array.new }
    end

    # Check if messages of given type were received at_least n times
    def received? message_type, times=1
      @receive_lock.synchronize do
        received[message_type].size >= times
      end
    end

    # Check if all given conditions are satisfied
    def satisfied? *conditions
      !conditions.empty? &&
      conditions.inject(true) do |result, condition|
        result && if condition.is_a?(Symbol)
        received?(condition)
        elsif condition.is_a?(Array)
          received?(*condition)
        elsif condition.respond_to?(:call)
          condition.call
        else
          error "Unknown wait condition #{condition}"
        end
      end
    end

    # Wait for specific condition(s) - given as callable/block, or
    # message type(s) - given as Symbol or [Symbol, times] pair.
    # Timeout after given time or 1 second.
    def wait_for *args, &block
      timeout = args.find { |arg| arg.is_a? Numeric } # extract timeout from args
      end_time = Time.now + (timeout || 1) # default timeout 1 sec
      conditions = args.delete_if { |arg| arg.is_a? Numeric }.push(block).compact

      until end_time < Time.now || satisfied?(*conditions)
        if @reader
          sleep 0.05
        else
          process_messages 50
        end
      end
    end

    ### Working with Incoming messages from IB

    # Start reader thread that continuously reads messages from @socket in background.
    # If you don't start reader, you should manually poll @socket for messages
    # or use #process_messages(msec) API.
    def start_reader
      Thread.abort_on_exception = true
      @reader_running = true
      @reader = Thread.new do
        process_messages while @reader_running
      end
    end

    def reader_running?
      @reader_running && @reader && @reader.alive?
    end

    # Process incoming messages during *poll_time* (200) msecs, nonblocking
    def process_messages poll_time = 200 # in msec
      time_out = Time.now + poll_time/1000.0
      while (time_left = time_out - Time.now) > 0
        # If socket is readable, process single incoming message
        process_message if select [socket], nil, nil, time_left
      end
    end

    # Process single incoming message (blocking!)
    def process_message
      msg_id = socket.read_int # This read blocks!

      # Debug:
      log.debug "Got message #{msg_id} (#{Messages::Incoming::Classes[msg_id]})"

      # Create new instance of the appropriate message type,
      # and have it read the message from socket.
      # NB: Failure here usually means unsupported message type received
      error "Got unsupported message #{msg_id}" unless Messages::Incoming::Classes[msg_id]
      msg = Messages::Incoming::Classes[msg_id].new(socket)

      # Deliver message to all registered subscribers, alert if no subscribers
      @subscribe_lock.synchronize do
        subscribers[msg.class].each { |_, subscriber| subscriber.call(msg) }
      end
      log.warn "No subscribers for message #{msg.class}!" if subscribers[msg.class].empty?

      # Collect all received messages into a @received Hash
      if options[:received]
        @receive_lock.synchronize do
          received[msg.message_type] << msg
        end
      end
    end

    ### Sending Outgoing messages to IB

    # Send an outgoing message.
    def send_message what, *args
      message =
      case
      when what.is_a?(Messages::Outgoing::AbstractMessage)
        what
      when what.is_a?(Class) && what < Messages::Outgoing::AbstractMessage
        what.new *args
      when what.is_a?(Symbol)
        Messages::Outgoing.const_get(what).new *args
      else
        error "Only able to send outgoing IB messages", :args
      end
      error "Not able to send messages, IB not connected!" unless connected?
      message.send_to socket
    end

    alias dispatch send_message # Legacy alias

    # Place Order (convenience wrapper for send_message :PlaceOrder).
    # Assigns client_id and order_id fields to placed order. Returns assigned order_id.
    def place_order order, contract
      order.place contract, self  if order.is_a? IB::Order
    end

    # Modify Order (convenience wrapper for send_message :PlaceOrder). Returns order_id.
    def modify_order order, contract
      order.modify contract, self
    end

    # Cancel Orders by their local ids (convenience wrapper for send_message :CancelOrder).
    def cancel_order *local_ids
      local_ids.each do |local_id|
        send_message :CancelOrder, :local_id => local_id.to_i
      end
    end

    protected

    def random_id
      rand 999999999
    end

  end # class Connection
end # module IB
