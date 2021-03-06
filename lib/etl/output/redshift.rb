require 'tempfile'
require 'aws-sdk'
require 'csv'
require_relative '../redshift/client'
require_relative '../redshift/table'
require_relative '../util/tmp_util'

module ETL::Output

  # Class that contains shared logic for loading data from S3 to Redshift.
  # Deprecated! Don't use this any more!
  class Redshift < Base
    attr_accessor :load_strategy, :client, :aws_params, :dest_table, :delimiter, :create_table

    def initialize(load_strategy, conn_params, aws_params, delimiter: "\u0001", create_table: true)
      super()

      @aws_params = aws_params
      @load_strategy = load_strategy
      @bucket = @aws_params[:s3_bucket]
      @random_key = [*('a'..'z'),*('0'..'9')].shuffle[0,10].join
      @delimiter = delimiter
      @create_table = create_table
      @client = ::ETL::Redshift::Client.new(conn_params, aws_params)
    end

    def csv_file
      @csv_file ||= ETL::TmpUtil.by_day(@client.tmp_dir, 's3', dest_table)
    end

    def exec_query(sql)
      @client.fetch(sql)
    end

    # Name of the destination table. By default we assume this is the class
    # name but you can override this in the parameters.
    def dest_table
      @dest_table ||
        ETL::StringUtil::camel_to_snake(ETL::StringUtil::base_class_name(self.class.name))
    end

    def tmp_table
      dest_table+"_"+@random_key
    end

    def table_schema
      @table_schema ||= begin
        h = {}
        results = @client.columns(dest_table)
        results.each { |result| h[result["column"].to_sym] = result["type"] }
        h
      end
    end

    def schema
      @schema ||= (default_schema || ETL::Redshift::Table.new(dest_table))
    end

    def primary_keys
      @primary_keys ||= schema.primary_key
    end

    def dist_keys
      @dist_keys ||= schema.dist_key
    end

    def sort_keys
      @sort_keys ||= schema.sort_key
    end

    # Returns string that can be used as the database type given the
    # ETL::Schema::Column object
    def col_type_str(col)
      case col.type
        when :varchar
          "varchar(#{col.width})"
        when :timestamp
          "timestamp"
        when :float
          "float8"
        when :numeric
          "numeric(#{col.width}, #{col.precision})"
        else
          # Allow other types to just flow through, which gives us a simple
          # way of supporting columns that are coming in through db reflection
          # even if we don't know what they are.
          col.type.to_s
      end
    end

    def create_staging_table
      full_table_name = "#{schema.schema}.#{schema.name}"

      # create temp table to add data to.
      temp_table = ::ETL::Redshift::Table.new(tmp_table, { temp: true, like: full_table_name })
      @client.create_table(temp_table)

      sql =<<SQL
        COPY #{tmp_table}
        FROM 's3://#{@bucket}/#{tmp_table}'
        IAM_ROLE '#{@aws_params[:role_arn]}'
        TIMEFORMAT AS 'auto'
        DATEFORMAT AS 'auto'
        DELIMITER '#{@delimiter}'
        REGION '#{@aws_params[:region]}'
        TRUNCATECOLUMNS
SQL

      @client.execute(sql)
    end

    def upload_to_s3
      s3_resource = Aws::S3::Resource.new(region: @aws_params[:region])
      s3_resource.bucket(@bucket).object(tmp_table).upload_file(csv_file)
    end

    def delete_object_from_s3
      s3_client = Aws::S3::Client.new(region: @aws_params[:region])
      s3_response = s3_client.delete_object({
        bucket: @bucket,
        key: tmp_table
      })
    end

    def load_from_s3
      full_dest_table = "#{@schema.schema}.#{@schema.name}"
      # delete existing rows based on load strategy
      case @load_strategy
      when :update
        # don't delete anything
      when :upsert
        # don't delete anything
      when :insert_append
        # don't delete anything
      when :insert_table
        # clear out existing table
        sql = <<SQL
delete from #{full_dest_table};
SQL
        @client.execute_dui(sql)
      else
        raise ETL::OutputError, "Invalid load strategy '#{load_strategy}'"
      end

      # handle upsert/update
      if [:update, :upsert].include?(@load_strategy)
        #get_primarykey
        pks = primary_keys

        if pks.nil? || pks.empty?
          raise ETL::SchemaError, "Table '#{full_dest_table}' does not have a primary key"
        elsif !pks.is_a?(Array)
          # convert to array
          pks = [pks]
        end

        #create staging table
        create_staging_table

        sql = <<SQL
        select * from #{tmp_table}
SQL

        r = @client.fetch(sql)

        if @load_strategy == :upsert
          sql = <<SQL
          DELETE FROM #{full_dest_table}
          USING #{tmp_table} s
          WHERE #{pks.collect{ |pk| "#{full_dest_table}.#{pk} = s.#{pk}" }.join(" and ")}
SQL
          @client.execute_dui(sql)

          sql = <<SQL
          INSERT INTO #{full_dest_table}
          SELECT * FROM #{tmp_table}
SQL
          @client.execute_insert(sql)

        # handle upsert(primary key is required)
        elsif @load_strategy == :update
          #build query string for updating columns
          update_cols = schema.columns.keys
          pks.each do |pk|
            update_cols.delete(pk)
          end

          sql = <<SQL
  update #{full_dest_table}
  set #{update_cols.collect{ |x| "\"#{x}\" = s.#{x}"}.join(", ")}
  from #{tmp_table} s
  where #{pks.collect{ |pk| "#{full_dest_table}.#{pk} = s.#{pk}" }.join(" and ")}
SQL

          @client.execute(sql)
        end

      else
        sql = <<SQL
        COPY #{full_dest_table}
        FROM 's3://#{@bucket}/#{tmp_table}'
        IAM_ROLE '#{@aws_params[:role_arn]}'
        TIMEFORMAT AS 'auto'
        DATEFORMAT AS 'auto'
        DELIMITER '#{@delimiter}'
        REGION '#{@aws_params[:region]}'
        TRUNCATECOLUMNS
SQL
        @client.execute(sql)
      end
    end

    def trim_newline(input)
      return input unless input.is_a? String
      input.gsub("\n", " ")
    end

    # Runs the ETL job
    def run_internal
      rows_processed = 0
      msg = ''

      # Not sure how odbc uses a transation so skipping this for now.

      # create destination table if it doesn't exist
      # eventually we will remove this
      @client.create_table(schema) if @create_table
      # Load data into temp csv
      # If the table exists, use the order of columns. Otherwise, use @header
      ::CSV.open(csv_file, "w", {:col_sep => @delimiter} ) do |c|
        reader.each_row do |erow|
          # Remove line break from all columns so that Redshift can detect delimiter
          # Need this method since ESCAPE option with COPY command on Redshift does not work
          row = erow.each_with_object({}) { |r, h| h[r[0].to_s] = trim_newline(r[1]) }

          if schema && !schema.columns.empty? 
            s = schema.columns.keys.map { |k| row[k.to_s] }
            if !s.nil?
              c << s
              rows_processed += 1
            end
          else
            s = table_schema.map { |k, v| row[k.to_s] }
            c << s
            rows_processed += 1
          end
        end
      end

      if rows_processed > 0
        #To-do: load data into S3
        upload_to_s3

        # Load s3 data into destination table
        load_from_s3

        # delete s3 data
        delete_object_from_s3

        # delete local file
        ::File.delete(csv_file)
      end

      @client.disconnect
      msg = "Processed #{rows_processed} input rows for #{dest_table}"
      ETL::Job::Result.success(rows_processed, msg)
    end
  end
end
