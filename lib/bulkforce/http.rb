require "net/https"
require "nori"
require "csv"

class Bulkforce
  module Http
    extend self

    def login *args
      r = Http::Request.login(*args)
      process_soap_response(nori.parse(process_http_request(r)))
    end

    def oauth_login *args
      r = Http::Request.oauth_login(*args)
      process_oauth_response(nori.parse(process_http_request(r)))
    end

    def create_job *args
      r = Http::Request.create_job(*args)
      process_xml_response(nori.parse(process_http_request(r)))
    end

    def close_job *args
      r = Http::Request.close_job(*args)
      process_xml_response(nori.parse(process_http_request(r)))
    end

    def add_batch *args
      r = Http::Request.add_batch(*args)
      process_xml_response(nori.parse(process_http_request(r)))
    end

    def query_batch *args
      r = Http::Request.query_batch(*args)
      process_xml_response(nori.parse(process_http_request(r)))
    end

    def query_batch_result_id *args
      r = Http::Request.query_batch_result_id(*args)
      process_xml_response(nori.parse(process_http_request(r)))
    end

    def query_batch_result_id_csv *args
      r = Http::Request.query_batch_result_id(*args)
      normalize_csv(process_http_request(r))
    end

    def query_batch_result_data *args
      r = Http::Request.query_batch_result_data(*args)
      normalize_csv(process_http_request(r))
    end

    def add_file_upload_batch instance, session_id, job_id, data, api_version
      headers = {
        "Content-Type" => "zip/csv",
        "X-SFDC-Session" => session_id}
      r = Http::Request.new(
        :post,
        Http::Request.instance_host(instance),
        "/services/async/#{api_version}/job/#{job_id}/batch",
        data,
        headers)
      process_xml_response(nori.parse(process_http_request(r)))
    end

    def process_http_request(r)
      http = http_client(r.host)
      http_request = Net::HTTP.
      const_get(r.http_method.capitalize).
        new(r.path, r.headers)
      http_request.body = r.body if r.body
      http.request(http_request).body
    end

    private

    def http_client(host)
      if proxy = Bulkforce.configuration.proxy
        proxy_uri = URI(proxy)
        proxy_host, proxy_port = proxy_uri.host, proxy_uri.port
        proxy_username = Bulkforce.configuration.proxy_username
        proxy_username = Bulkforce.configuration.proxy_password
      else
        proxy_username = proxy_password = proxy_host = proxy_host = proxy_port = nil
      end

      Net::HTTP.new(
        host,
        443,
        proxy_host,
        proxy_port,
        proxy_username,
        proxy_password
      ).tap do |http|
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
    end

    def nori
      Nori.new(
        :advanced_typecasting => true,
        :strip_namespaces => true,
        :convert_tags_to => lambda { |tag| tag.snakecase.to_sym })
    end

    def process_xml_response res
      if res[:error]
        raise "#{res[:error][:exception_code]}: #{res[:error][:exception_message]}"
      end

      res.values.first
    end

    def normalize_csv res
      res.gsub(/\n\s+/, "\n")
    end

    def process_soap_response res
      raw_result = res.fetch(:body){ res.fetch(:envelope).fetch(:body) }
      raise raw_result[:fault][:faultstring] if raw_result[:fault]

      login_result = raw_result[:login_response][:result]
      instance = Helper.fetch_instance_from_server_url(login_result[:server_url])
      login_result.merge(instance: instance)
    end

    def process_oauth_response res
      inner = res.fetch(:o_auth)

      if inner[:error]
        raise "#{inner[:error]}: #{inner[:error_description]}"
      end

      {
        server_url: inner.fetch(:instance_url),
        session_id: inner.fetch(:access_token),
        instance: Helper.fetch_instance_from_server_url(inner.fetch(:instance_url)),
      }
    end

    class Request
      attr_reader :path
      attr_reader :host
      attr_reader :body
      attr_reader :headers
      attr_reader :http_method

      def initialize http_method, host, path, body, headers
        @http_method  = http_method
        @host         = host
        @path         = path
        @body         = body
        @headers      = headers
      end

      def self.login host, username, password, api_version
        body =  %Q{<?xml version="1.0" encoding="utf-8" ?>
        <env:Envelope xmlns:xsd="http://www.w3.org/2001/XMLSchema"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
            xmlns:env="http://schemas.xmlsoap.org/soap/envelope/">
          <env:Body>
            <n1:login xmlns:n1="urn:partner.soap.sforce.com">
              <n1:username>#{username}</n1:username>
              <n1:password>#{password}</n1:password>
            </n1:login>
          </env:Body>
        </env:Envelope>}
        headers = {
          "Content-Type" => "text/xml; charset=utf-8",
          "SOAPAction" => "login"
        }
        Http::Request.new(
          :post,
          host,
          "/services/Soap/u/#{api_version}",
          body,
          headers)
      end

      def self.oauth_login(host, client_id, client_secret, refresh_token)
        headers = {
          "Content-Type" => "application/x-www-form-urlencoded",
          "Accept" => "application/xml",
        }

        body = {
          grant_type: "refresh_token",
          client_id: client_id,
          client_secret: client_secret,
          refresh_token: refresh_token
        }.inject("") do |string, (k,v)|
          string += "#{k}=#{v}&"
        end

        Http::Request.new(
          :post,
          host,
          "/services/oauth2/token",
          body,
          headers)
      end

      def self.create_job instance, session_id, operation, sobject, content_type, api_version, external_field = nil
        external_field_line = external_field ?
          "<externalIdFieldName>#{external_field}</externalIdFieldName>" : nil
        body = %Q{<?xml version="1.0" encoding="utf-8" ?>
          <jobInfo xmlns="http://www.force.com/2009/06/asyncapi/dataload">
            <operation>#{operation}</operation>
            <object>#{sobject}</object>
            #{external_field_line}
            <contentType>#{content_type}</contentType>
          </jobInfo>
        }
        headers = {
          "Content-Type" => "application/xml; charset=utf-8",
          "X-SFDC-Session" => session_id}
        Http::Request.new(
          :post,
          instance_host(instance),
          "/services/async/#{api_version}/job",
          body,
          headers)
      end

      def self.close_job instance, session_id, job_id, api_version
        body = %Q{<?xml version="1.0" encoding="utf-8" ?>
          <jobInfo xmlns="http://www.force.com/2009/06/asyncapi/dataload">
            <state>Closed</state>
          </jobInfo>
        }
        headers = {
          "Content-Type" => "application/xml; charset=utf-8",
          "X-SFDC-Session" => session_id}
        Http::Request.new(
          :post,
          instance_host(instance),
          "/services/async/#{api_version}/job/#{job_id}",
          body,
          headers)
      end

      def self.add_batch instance, session_id, job_id, data, api_version
        headers = {"Content-Type" => "text/csv; charset=UTF-8", "X-SFDC-Session" => session_id}
        Http::Request.new(
          :post,
          instance_host(instance),
          "/services/async/#{api_version}/job/#{job_id}/batch",
          data,
          headers)
      end

      def self.query_batch instance, session_id, job_id, batch_id, api_version
        headers = {"X-SFDC-Session" => session_id}
        Http::Request.new(
          :get,
          instance_host(instance),
          "/services/async/#{api_version}/job/#{job_id}/batch/#{batch_id}",
          nil,
          headers)
      end

      def self.query_batch_result_id instance, session_id, job_id, batch_id, api_version
        headers = {
          "Content-Type" => "application/xml; charset=utf-8",
          "X-SFDC-Session" => session_id}
        Http::Request.new(
          :get,
          instance_host(instance),
          "/services/async/#{api_version}/job/#{job_id}/batch/#{batch_id}/result",
          nil,
          headers)
      end

      def self.query_batch_result_data(instance,
        session_id,
        job_id,
        batch_id,
        result_id,
        api_version)
        headers = {
          "Content-Type" => "text/csv; charset=UTF-8",
          "X-SFDC-Session" => session_id}
        Http::Request.new(
          :get,
          instance_host(instance),
          "/services/async/#{api_version}" \
            "/job/#{job_id}/batch/#{batch_id}/result/#{result_id}",
          nil,
          headers)
      end

      def self.instance_host instance
        "#{instance}.salesforce.com"
      end
    end
  end
end
