require 'digest/sha2'
module Technoweenie # :nodoc:
  module AttachmentFu # :nodoc:
    module Backends
      # = Ftp Storage Backend
      #
      # Enables use of an ftp server for storage.
      # (Adapted s3 backend to the ftp scenario)
      #
      # == Configuration
      #
      # Configuration is done via <tt>Rails.root/config/attachment_fu_ftp.yml</tt> and is loaded according to the <tt>Rails.env</tt>.
      # The minimum connection options that you must specify are, the ftp login and password.
      #
      # Example configuration (Rails.root/config/attachment_fu_ftp.yml)
      # (Not sure how ftp-library supports ports different from standard FTP port)
      #
      #   development:
      #     server: hostname
      #     login: <your login>
      #     password: <your password>
      #     base_upload_path: <path on ftp server>
      #     base_url: <url where files can be read after uploading>
      #
      #   test:
      #     server: hostname
      #     login: <your login>
      #     password: <your password>
      #     base_upload_path: <path on ftp server>
      #     base_url: <url where files can be read after uploading>
      #
      #   production:
      #     server: hostname
      #     login: <your login>
      #     password: <your password>
      #     base_upload_path: <path on ftp server>
      #     base_url: <url where files can be read after uploading>
      #
      # You can change the location of the config path by passing a full path to the :ftp_config_path option.
      #
      #   has_attachment :storage => :ftp, :ftp_config_path => (Rails.root + '/config/attachment_fu_ftp.yml')
      #
      # === Required configuration parameters
      #
      # * <tt>:login</tt> - The login for your ftp account.
      # * <tt>:password</tt> - The password for your ftp account.
      # * <tt>:base_upload_path</tt> - Base directory on ftp server
      #
      # If any of these required arguments is missing, an exception will be raised.
      #
      # === Optional configuration parameters
      #
      # == Usage
      #
      # To specify ftp as the storage mechanism for a model, set the acts_as_attachment <tt>:storage</tt> option to <tt>:ftp</tt>.
      #
      #   class Photo < ActiveRecord::Base
      #     has_attachment :storage => :ftp
      #   end
      #
      # === Customizing the path
      #
      # By default, files are prefixed using a pseudo hierarchy in the form of <tt>:table_name/:id</tt>, which results
      # in urls that look like: [base_url]/:table_name/:id/:filename with :table_name
      # representing the customizable portion of the path. You can customize this prefix using the <tt>:path_prefix</tt>
      # option:
      #
      #   class Photo < ActiveRecord::Base
      #     has_attachment :storage => :ftp, :path_prefix => 'my/custom/path'
      #   end
      #
      # Which would result in URLs like <tt>[base_url]/my/custom/path/:id/:filename</tt>
      #
      # === Other options
      #
      # Of course, all the usual configuration options apply, such as content_type and thumbnails:
      #
      #   class Photo < ActiveRecord::Base
      #     has_attachment :storage => :ftp, :content_type => ['application/pdf', :image], :resize_to => 'x50'
      #     has_attachment :storage => :ftp, :thumbnails => { :thumb => [50, 50], :geometry => 'x50' }
      #   end
      #
      # === Accessing FTP URLs
      #
      # You can get an object's URL using the ftp_url accessor. For example, assuming that for your postcard app
      # you had a path_prefix like 'postcard_world_development', and an attachment model called Photo:
      #
      #   @postcard.ftp_url # => [base_url]/postcard_world_development/photos/1/mexico.jpg
      #
      module FtpBackend
        class RequiredLibraryNotFoundError < StandardError; end
        class ConfigFileNotFoundError < StandardError; end

        def self.included(base) #:nodoc:
          mattr_reader :ftp_config,
                       :base_upload_path

          begin
            require 'net/ftp'
          rescue LoadError
            raise RequiredLibraryNotFoundError.new('Net::FTP could not be loaded')
          end

          begin
            @@ftp_config_path = base.attachment_options[:ftp_config_path] || Rails.root.join('config', 'attachment_fu_ftp.yml').to_s
            @@ftp_config = YAML.load(ERB.new(File.read(@@ftp_config_path)).result)[Rails.env].symbolize_keys
          end

          @@base_upload_path = ftp_config[:base_upload_path]

          base.before_update :rename_file
        end

        # Overwrites the base filename writer in order to store the old filename
        def filename=(value)
          @old_filename = filename unless filename.nil? || @old_filename
          write_attribute :filename, sanitize_filename(value)
        end

        # The attachment ID used in the full path of a file
        def attachment_path_id
          ((respond_to?(:parent_id) && parent_id) || id)
        end

        # The pseudo hierarchy containing the file relative to the bucket name
        # Example: <tt>:table_name/:id</tt>
        def base_path
          File.join(path_prefix)
        end

        def base_url
          ftp_config[:base_url] || ''
        end

        def path_prefix
          attachment_options[:path_prefix] || ''
        end

        # The full path to the file relative to the bucket name
        # Example: <tt>:table_name/:id/:filename</tt>
        def full_filename(thumbnail = nil)
          File.join(base_path, *partitioned_path(thumbnail_name_for(thumbnail)))
        end

        def ftp_url(thumbnail = nil)
          File.join(ftp_config[:base_url], full_filename(thumbnail))
        end
        alias :public_filename :ftp_url

        def create_temp_file
          tempfile = Tempfile.new(nil, Technoweenie::AttachmentFu.tempfile_path)

          Net::FTP.open(ftp_config[:server], ftp_config[:login], ftp_config[:password]) do |ftp|
            ftp.getbinaryfile(File.join(ftp_config[:base_upload_path], full_filename), tempfile.path)
          end

          tempfile
        end

        def current_data
          create_temp_file.read
        end

        # Partitions the given path into an array of path components.
        #
        # For example, given an <tt>*args</tt> of ["foo", "bar"], it will return
        # <tt>["0000", "0001", "foo", "bar"]</tt> (assuming that that id returns 1).
        #
        # If the id is not an integer, then path partitioning will be performed by
        # hashing the string value of the id with SHA-512, and splitting the result
        # into 4 components. If the id a 128-bit UUID (as set by :uuid_primary_key => true)
        # then it will be split into 2 components.
        #
        # To turn this off entirely, set :partition => false.
        def partitioned_path(*args)
          if respond_to?(:attachment_options) && attachment_options[:partition] == false
            args
          elsif attachment_options[:uuid_primary_key]
            # Primary key is a 128-bit UUID in hex format. Split it into 2 components.
            path_id = attachment_path_id.to_s
            component1 = path_id[0..15] || "-"
            component2 = path_id[16..-1] || "-"
            [component1, component2] + args
          else
            path_id = attachment_path_id
            if path_id.is_a?(Integer)
              # Primary key is an integer. Split it after padding it with 0.
              ("%08d" % path_id).scan(/..../) + args
            else
              # Primary key is a String. Hash it, then split it into 4 components.
              hash = Digest::SHA512.hexdigest(path_id.to_s)
              [hash[0..31], hash[32..63], hash[64..95], hash[96..127]] + args
            end
          end
        end
        protected
          # Called in the after_destroy callback
          def destroy_file
            return true if ftp_config[:read_only]

            dest_path = File.join(ftp_config[:base_upload_path], full_filename)
            Net::FTP.open(ftp_config[:server], ftp_config[:login], ftp_config[:password]) do |ftp|
              @deleted = ftp.delete(dest_path) rescue nil# gone
            end

            @deleted
          end

          def rename_file
            if @old_filename and @old_filename == filename and not ftp_config[:read_only]
              old_full_filename = File.join(base_path, @old_filename)
              src_path = File.join(ftp_config[:base_upload_path], old_full_filename)
              dest_path = File.join(ftp_config[:base_upload_path], full_filename)

              Net::FTP.open(ftp_config[:server], ftp_config[:login], ftp_config[:password]) do |ftp|
                ftp.rename(src_path, dest_path)
              end
            end

            @old_filename = nil
            true
          end

          def save_to_storage
            if save_attachment? and not ftp_config[:read_only]
              dest_path = File.join(ftp_config[:base_upload_path], full_filename)
              Net::FTP.open(ftp_config[:server], ftp_config[:login], ftp_config[:password]) do |ftp|
                ftp.makedirs_(File.dirname(dest_path))
                ftp.putbinaryfile( temp_path, dest_path, 1024)
              end
            end

            @old_filename = nil
            true
          end
      end
    end
  end
end


# Based on http://rubyforge.org/projects/misctools/.../ftptools.rb
class Net::FTP
  # The ftp-equivalent of 'mkdir -p path'
  # However, if ftp-user doesn't have required permissions
  # the method does not fail, while the path has not been created
  def makedirs_(path)
    route = []
    path.split(File::SEPARATOR).each do |dir|
      route << dir
      current_dir = File.join(route)
      mkdir(current_dir) rescue nil # if dir exists, ignore
    end
  end
end
