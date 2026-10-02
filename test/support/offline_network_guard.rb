# frozen_string_literal: true

require "net/http"
require "socket"

module AdventureFinderOfflineNetworkGuard
  MESSAGE = "FO-03 offline acceptance forbids network, provider, and inference access"

  module TcpClassMethods
    def new(*)
      raise IOError, MESSAGE
    end

    def open(*)
      raise IOError, MESSAGE
    end
  end

  module SocketClassMethods
    def tcp(*)
      raise IOError, MESSAGE
    end

    def new(domain, *)
      return super if domain == Socket::AF_UNIX

      raise IOError, MESSAGE
    end
  end

  module HttpMethods
    def connect
      raise IOError, MESSAGE
    end
  end
end

TCPSocket.singleton_class.prepend(AdventureFinderOfflineNetworkGuard::TcpClassMethods)
UDPSocket.singleton_class.prepend(AdventureFinderOfflineNetworkGuard::TcpClassMethods)
Socket.singleton_class.prepend(AdventureFinderOfflineNetworkGuard::SocketClassMethods)
Net::HTTP.prepend(AdventureFinderOfflineNetworkGuard::HttpMethods)
