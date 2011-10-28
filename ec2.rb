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

def image_name_for(str)
  bucket_name_for(str)
end

def colorize(text, color_code)
  "\e[#{color_code}m#{text}\e[0m"
end
def red(text); colorize(text, 31); end
def green(text); colorize(text, 32); end
def yellow(text); colorize(text, 33); end

load_config

puts green("\nWelcome to EC2Bundlr!\n=====================\n")
@config[:ec2_hostname]      = prompt("EC2 hostname to bundle",  @config[:ec2_hostname]); save_config; puts ""

loop do
  @config[:image_name]      = prompt("AMI name",                @config[:image_name]); save_config; puts ""

  if @config[:image_name].length > 128 || @config[:image_name].length < 3 || @config[:image_name].match(/[^a-z0-9\(\)\.\-\/\_\s]/i)
    puts red("AMI name must be between 3 and 128 characters long, and may contain letters, numbers, '(', ')', '.', '-', '/' and '_'.")
  else
    break
  end
end
  
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
  
  desc "Bundle an EC2 instance into an AMI"
  task :bundle do
    config = load_config
    ami_id = nil
    
    rt = Benchmark.realtime {
      detect_ec2_tools

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
        arch = if data.chomp == "x86_64"
          "x86_64"
        else
          "i386"
        end
      end
      puts green("Detected instance architecture: #{arch}.")

      puts green("Creating the EC2 Bundle...")
      sudo "mkdir -p /mnt/image/"
      sudo "ec2-bundle-vol -r #{arch} -d /mnt/image -p #{image_name_for(config[:image_name])} -u #{config[:amazon_account_id]} -k /mnt/#{private_key_filename} -c /mnt/#{cert_filename} -s 10240 -e /mnt,/home/ubuntu/.ssh,/dev --kernel `curl -s http://169.254.169.254/latest/meta-data/kernel-id`"
      
      puts green("Uploading the EC2 Bundle to S3...")
      s3_path = "#{config[:s3_bucket_name]}/image_bundles/#{bucket_name_for(config[:image_name])}"
      sudo "ec2-upload-bundle -b #{s3_path} -m /mnt/image/#{image_name_for(config[:image_name])}.manifest.xml -a #{config[:amazon_access_key]} -s #{config[:amazon_secret_key]}"

      puts green("Registering the AMI...")
      sudo "ec2-register -a #{arch} -n \"#{config[:image_name]}\" -K /mnt/#{private_key_filename} -C /mnt/#{cert_filename} #{s3_path}/#{image_name_for(config[:image_name])}.manifest.xml" do |ch, stream, data|
        if data && data.match(/ami\-[a-z0-9]*/i)
          ami_id = data.match(/ami\-[a-z0-9]*/i)[0]
          break
        end
      end

      # Cleaning up after myself
      puts green("Cleaning up after myself...")
      clean_history
    }
    
    min, sec = rt.divmod(60)
    puts green("\nDone! Took #{min} minutes and #{sec.to_i} seconds.\n\nYour new image '#{config[:image_name]}' has been registered as #{ami_id}.")
  end

  task :detect_ec2_tools do
    expected_api_tools_version = "1.3-57419 2010-08-31"
    expected_ami_tools_version = "1.3-49953 20071010"
    ec2_api_tools_version, ec2_ami_tools_version = "", ""

    puts green("Detecting if EC2 AMI/API tools are installed...")
    
    run("ec2-version") do |ch, stream, data|
      ec2_api_tools_version += data unless data.nil? || data.empty?
    end; ec2_api_tools_version = (ec2_api_tools_version || "").chomp.split("\n")[0]

    if expected_api_tools_version == ec2_api_tools_version
      puts green("Detected EC2 API Tools #{ec2_api_tools_version}. OK.")
    elsif ec2_api_tools_version.nil? || ec2_api_tools_version.empty?
      puts red("Couldn't find EC2 API Tools. Exiting.")
      exit 1
    else
      puts yellow("Detected EC2 API Tools #{ec2_api_tools_version}. Expected #{expected_api_tools_version}. Use at your own risks!")
    end



    run("ec2-ami-tools-version") do |ch, stream, data|
      ec2_ami_tools_version += data unless data.nil? || data.empty?
    end; ec2_ami_tools_version = (ec2_ami_tools_version || "").chomp.split("\n")[0]

    if expected_ami_tools_version == ec2_ami_tools_version
      puts green("Detected EC2 AMI Tools #{ec2_ami_tools_version}. OK.")
    elsif ec2_ami_tools_version.nil? || ec2_ami_tools_version.empty?
      puts red("Couldn't find EC2 AMI Tools. Exiting.")
      exit 1
    else
      puts yellow("Detected EC2 AMI Tools #{ec2_ami_tools_version}. Expected #{expected_ami_tools_version}. Use at your own risks!")
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
