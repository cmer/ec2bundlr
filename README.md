# EC2Bundlr

EC2Bundlr is a simple and interactive Capistrano task to bundle an EC2 instance into an AMI (Amazon Machine Image).

When executing EC2Bundlr, you will be asked many questions. EC2Bundlr will automatically remember your answers and save them in a file called config.yaml. This way, you will not need to reconfigure EC2Bundlr from scratch every time you execute it. You can simply change what needs to be changed on subsequent runs, such as the host name and the AMI name.

## Usage

    $ cap ec2:bundle
    
## Requirements

#### Localhost

 -  Ruby 1.8.7 or 1.9.2
 -  Capistrano (gem install capistrano)

#### Remote EC2 host 

 -  euca2ools (apt-get install euca2ools or [http://bit.ly/euca2ools_guide](http://bit.ly/euca2ools_guide))

## License

Copyright (C) 2010 Carl Mercier

Distributed under the MIT License. See the LICENSE file.