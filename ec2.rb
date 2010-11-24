CONFIG_FILE = "config.yaml"
require 'yaml'
require 'readline'
require 'benchmark'

def prompt(msg, default = "", allow_empty = false)
  default = "" if default.nil?
  msg += " [#{default}]" unless default.empty?
  msg += ": "

  val = ""
  loop do
    val = (Readline.readline(msg) || "").strip
    val = default if val.empty? && !default.empty?
    break if !val.empty? || (val.empty? && allow_empty)
  end
  val
end

def load_config
  @config = if File.exist?(CONFIG_FILE)
    YAML.load(File.open(CONFIG_FILE))
  else
    {}
  end
end

def save_config
  File.open(CONFIG_FILE, 'w') { |out| YAML.dump(@config, out) }
end

def bucket_name_for(str)
  str.gsub(/[^a-zA-Z0-9\-_\. ]/, '').gsub(/ /, '_')
end

def colorize(text, color_code)
  "\e[#{color_code}m#{text}\e[0m"
end
def red(text); colorize(text, 31); end
def green(text); colorize(text, 32); end

load_config

puts green("\nWelcome to EC2Bundlr!\n=====================\n")
@config[:ec2_hostname]      = prompt("EC2 hostname to bundle",  @config[:ec2_hostname]); save_config; puts ""
@config[:image_name]        = prompt("AMI name",                @config[:image_name]); save_config; puts ""
@config[:s3_bucket_name]    = prompt("S3 bucket name",          @config[:s3_bucket_name]); save_config; puts ""

puts green("\nHow should I connect to '#{@config[:ec2_hostname]}'?\n")
@config[:ssh_user]          = prompt("SSH username",            @config[:ssh_user] || "root"); save_config; puts ""
@config[:ssh_keypair]       = prompt("SSH keypair path (optional)", 
                                                                @config[:ssh_keypair], true); save_config; puts ""

puts green("\nAWS Credentials\n")
@config[:amazon_account_id] = prompt("Amazon Account ID (xxxx-xxxx-xxxx)",
                                                                @config[:amazon_account_id]); save_config; puts ""
@config[:amazon_access_key] = prompt("Amazon Access Key ID",    @config[:amazon_access_key]); save_config; puts ""
@config[:amazon_secret_key] = prompt("Amazon Secret Access Key", 
                                                                @config[:amazon_secret_key]); save_config; puts ""
@config[:ec2_cert]          = prompt("EC2 certificate path",    @config[:ec2_cert]); save_config; puts ""
@config[:ec2_private_key]   = prompt("EC2 private key path",    @config[:ec2_private_key]); save_config; puts ""

puts green("Configuration completed.\n\n\n")

role :libs, @config[:ec2_hostname]
set :user, @config[:ssh_user]
ssh_options[:keys] = @config[:ssh_keypair] unless (@config[:ssh_keypair] || "").empty?

namespace :ec2 do
  task :bundle do
    rt = Benchmark.realtime {
      detect_euca2ools
      config = load_config

      # Copy the certificate and private key to the remote computer.
      # Have to upload then move with sudo since the SSH user might not
      # have permissions to /mnt.
      private_key_filename = File.basename(config[:ec2_private_key])
      cert_filename = File.basename(config[:ec2_cert])
      upload("#{config[:ec2_private_key]}", "/tmp", :via => :scp)
      upload("#{config[:ec2_cert]}", "/tmp", :via => :scp)
      sudo "mv /tmp/#{private_key_filename} /mnt/"
      sudo "mv /tmp/#{cert_filename} /mnt/"

      clean_history

      # Find architecture type
      arch = nil
      run "uname -m" do |ch, stream, data|
        arch = if data == "x86_64"
          "x86_64"
        else
          "i386"
        end
      end
      puts green("Detected instance architecture: #{arch}.")

      puts green("Creating the EC2 Bundle...")
      sudo "mkdir -p /mnt/image/"
      sudo "euca-bundle-vol -d /mnt/image -c /mnt/#{cert_filename} -k /mnt/#{private_key_filename} -u #{config[:amazon_account_id]} -r #{arch}"

      puts green("Uploading the EC2 Bundle to S3...")
      s3_path = "#{config[:s3_bucket_name]}/image_bundles/#{bucket_name_for(config[:image_name])}"
      sudo "euca-upload-bundle -b #{s3_path} -m /mnt/image/image.manifest.xml -a #{config[:amazon_access_key]} -s #{config[:amazon_secret_key]} -U http://s3.amazonaws.com"

      puts green("Registering the AMI...")
      sudo "euca-register -a #{config[:amazon_access_key]} -s #{config[:amazon_secret_key]} -U http://ec2.amazonaws.com #{s3_path}/image.manifest.xml"

      # Cleaning up after myself
      puts green("Cleaning up after myself...")
      clean_history
    }
    
    min, sec = rt.divmod(60)
    puts green("\nDone! Took #{min} minutes and #{sec.to_i} seconds.\n")
  end

  task :detect_euca2ools do
    puts green("Detecting if 'euca2ools' is installed...")

    run "euca-version" do |ch, stream, data|
      data.chomp!
      if stream == :out && !data.match(/^1\.2/)
        puts red("WARNING: This script was only tested with version 1.2 of euca2ools, but your version is: #{data}. Use at your own risk!")
      elsif stream == :out
        puts green("Detected euca2ools #{data}.")
      else
        puts red("Did not find the required package 'euca2ools'. Please install it on the remote host.\n$ apt-get install euca2ools.")
      end
    end
  end

  task :clean_history do
    sudo "rm -fr /mnt/image"
    sudo "rm --force /mnt/image /mnt/image.*"
    run "rm -f ~/.*hist*"
    sudo "rm -f /root/.*hist*"
    sudo "rm -f /var/log/*.gz"
    sudo "find /var/log -name mysql -prune -o -type f -print |  while read i; do sudo cp /dev/null $i; done "
  end

end
