require 'puppet'
require 'yaml'
require 'json'

begin
  require 'xmlrpc/client'
rescue LoadError => e
  Puppet.info "You need `xmlrpc/client` installed to use the IRC report"
end

unless Puppet.version >= '2.6.5'
  fail "This report processor requires Puppet version 2.6.5 or later"
end

Puppet::Reports.register_report(:irc) do

  configfile = File.join([File.dirname(Puppet.settings[:config]), "irc.yaml"])
  raise(Puppet::ParseError, "IRC report config file #{configfile} not readable") unless File.exist?(configfile)
  config = YAML.load_file(configfile)
  IRC_CMD_HOST = config[:irc_cmd_host]
  IRC_CHANNEL  = config[:irc_channel]
  IRC_NET      = config[:irc_net]
  GITHUB_USER  = config[:github_user]
  GITHUB_TOKEN = config[:github_token]

  desc <<-DESC
  Send notification of failed reports to an IRC channel and if configured create a Gist with the log output.
  DESC

  def process
    if self.status == 'failed'
      output = []
      self.logs.each do |log|
        output << log
      end

      message = "Puppet run for #{self.host} #{self.status} at #{Time.now.asctime}."
      if GITHUB_USER && GITHUB_TOKEN
        gist_id = gist(self.host,output)
        message = "#{message} Created a Gist showing the output at https://gist.github.com/#{gist_id}"
      end

      begin
        timeout(8) do
          Puppet.debug "Sending status for #{self.host} to IRC."
          server = XMLRPC::Client.new2(IRC_CMD_HOST)
          server.call('privmsg', IRC_NET, IRC_CHANNEL, message)
        end
      rescue Timeout::Error
         Puppet.error "Failed to send report to #{IRC_CMD_HOST} retrying..."
         max_attempts -= 1
         retry if max_attempts > 0
      end
    end
  end

  def gist(host,output)
    begin
      timeout(8) do
        res = Net::HTTP.post_form(URI.parse("http://gist.github.com/api/v1/json/new"), {
          "files[#{host}-#{Time.now.to_i.to_s}]" => output.join("\n"),
          "login" => GITHUB_USER,
          "token" => GITHUB_TOKEN,
          "description" => "Puppet run failed on #{host} @ #{Time.now.asctime}",
          "public" => false
        })
        gist_id = JSON.parse(res.body)["gists"].first["repo"]
      end
    rescue Timeout::Error
      Puppet.error "Timed out while attempting to create a GitHub Gist, retrying ..."
      max_attempts -= 1
      retry if max_attempts > 0
    end
  end
end
