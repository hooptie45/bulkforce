require "bulkforce/version"
require "bulkforce/configuration"
require "bulkforce/helper"
require "bulkforce/batch"
require "bulkforce/http"
require "bulkforce/connection_builder"
require "bulkforce/connection"
require "zip"

class Bulkforce
  SALESFORCE_API_VERSION = "33.0"

  class << self

    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

  end

  def initialize(options = {})
    merged_opts = self.class.configuration.to_h.merge(options)

    unless merged_opts[:host] =~ /salesforce.com\/?$/
      warn("WARNING: You are submitting credentials to a host other than salesforce.com")
    end

    @connection = Bulkforce::ConnectionBuilder.new(merged_opts).build
  end

  def org_id
    @connection.org_id
  end

  def upsert(sobject, records, external_field)
    start_job("upsert", sobject, records, external_field)
  end

  def update(sobject, records)
    start_job("update", sobject, records)
  end

  def insert(sobject, records)
    start_job("insert", sobject, records)
  end

  def delete(sobject, records)
    start_job("delete", sobject, records)
  end

  def query(sobject, query)
    job_id = @connection.create_job(
      "query",
      sobject,
      "CSV",
      nil)
    batch_id = @connection.add_query(job_id, query)
    @connection.close_job job_id
    batch_reference = Bulkforce::Batch.new @connection, job_id, batch_id
    batch_reference.final_status
  end

  private
  def start_job(operation, sobject, records, external_field=nil)
    attachment_keys = Bulkforce::Helper.attachment_keys(records)

    content_type = "CSV"
    zip_filename = nil
    request_filename = nil
    batch_id = -1
    if not attachment_keys.empty?
      tmp_filename = Dir::Tmpname.make_tmpname("bulk_upload", ".zip")
      zip_filename = "#{Dir.tmpdir}/#{tmp_filename}"
      Zip::File.open(zip_filename, Zip::File::CREATE) do |zipfile|
        Bulkforce::Helper.transform_values!(records, attachment_keys) do |path|
          relative_path = Bulkforce::Helper.absolute_to_relative_path(path, "")
          zipfile.add(relative_path, path) rescue Zip::ZipEntryExistsError
        end
        tmp_filename = Dir::Tmpname.make_tmpname("request", ".txt")
        request_filename = "#{Dir.tmpdir}/#{tmp_filename}"
        File.open(request_filename, "w") do |file|
          file.write(Bulkforce::Helper.records_to_csv(records))
        end
        zipfile.add("request.txt", request_filename)
      end

      content_type = "ZIP_CSV"
    end

    job_id = @connection.create_job(
      operation,
      sobject,
      content_type,
      external_field)
    if zip_filename
      batch_id = @connection.add_file_upload_batch job_id, zip_filename
      [zip_filename, request_filename].each do |file|
        File.delete(file) if file
      end
    else
      batch_id = @connection.add_batch job_id, records
    end

    @connection.close_job job_id
    Bulkforce::Batch.new @connection, job_id, batch_id
  end
end
