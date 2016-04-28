#!/usr/bin/env ruby

require 'optparse'
require 'optparse/time'
require 'optparse/uri'
require 'ostruct'
require 'pp'
require 'logger'
require 'net/http'
require 'set'
require 'json'
require 'resolv'

class Optparser
  def self.parse(args)
    options = OpenStruct.new
    options.marathon = ""
    options.haproxy = []
    options.interval = 60
    options.samples = 10
    options.cooldown = 5
    options.target_rps = 1000
    options.apps = Set.new
    options.threshold_percent = 0.5
    options.threshold_instances = 3
    options.intervals_past_threshold = 3
    options.marathonCredentials =  []
    options.haproxyCredentials = []

    opt_parser = OptionParser.new do |opts|
      opts.banner = "Usage: autoscale.rb [options]"

      opts.separator ""
      opts.separator "Specific options:"

      opts.on("--marathon URL", URI,
              "URL for Marathon") do |value|
        options.marathon = value
      end

      opts.on("--haproxy [URLs]",
              "Comma separate list of URLs for HAProxy. If this is a Mesos-DNS A-record, " +
              "all backends will be polled.") do |value|
        options.haproxy = value.split(/,/).map{|x|URI(x)}
      end

      opts.on("--interval Float", Float, "Number of seconds (N) between update intervals " +
              "(Default: #{options.interval})") do |value|
        options.interval = value
      end

      opts.on("--samples Integer", Integer, "Number of samples to average (Default: " +
              "#{options.samples})") do |value|
        options.samples = value
      end

      opts.on("--cooldown Integer", Integer, "Number of additional intervals to wait after making " +
              "a scale change (Default: #{options.cooldown})") do |value|
        options.cooldown = value
      end

      opts.on("--target-rps Integer", Integer, "Target number of requests per second per " +
              "app instance (Default: #{options.target_rps})") do |value|
        options.target_rps = value
      end

      opts.on("--apps [APPS]", "Comma separated list of <app>_<service port> pairs to monitor") do |value|
        options.apps.merge(value.split(/,/))
      end

      opts.on("--marathonCredentials [MarathonCredentials]", "Colon separated string of <username>:<password>") do |value|
        options.marathonCredentials = value.split(/:/)
      end

      opts.on("--haproxyCredentials [HAProxyCredentials]", "Colon separated string of <username>:<password>") do |value|
        options.haproxyCredentials = value.split(/:/)
      end

      opts.on("--threshold-percent Float", Float, "Scaling will occur when the target RPS " +
              "differs from the current RPS by at least this amount (Default: " +
              "#{options.threshold_percent})") do |value|
        options.threshold_percent = value
      end

      opts.on("--threshold-instances Integer", Integer, "Scaling will occur when the target number " +
              "of instances differs from the actual number by at least this amount (Default: " +
              "#{options.threshold_instances})") do |value|
        options.threshold_instances = value
      end

      opts.on("--intervals-past-threshold Integer", Integer, "An app won't be" +
              " scaled until it's past it's threshold for this many intervals (Default: " +
              "#{options.intervals_past_threshold})") do |value|
        options.intervals_past_threshold = value
      end

      opts.separator ""
      opts.separator "Common options:"

      opts.on_tail("-h", "--help", "Show this message") do
        puts opts
        exit
      end
    end

    opt_parser.parse!(args)
    options
  end
end


class Autoscale
  def initialize(options)
    @options = options
    @log = Logger.new(STDOUT)
    @log.level = Logger::INFO
    @log.formatter = proc do |severity, datetime, progname, msg|
      date_format = datetime.strftime("%FT%T")
      if severity == "ERROR" or severity == "WARN"
        "[#{date_format}] #{severity[0]}: #{msg}\n"
      else
        "[#{date_format}] #{msg}\n"
      end
    end
  end

  def run
    @log.info('Starting autoscale controller')
    @log.info("Options: #{@options.to_s}")
    @samples = 0

    @apps = {}
    @options.apps.each do |app|
      @apps[app] = {
        :rate => [],
        :rate_avg => 0,
        :name => app,
        :last_scaled => 0,
        :intervals_past_threshold => 0,
        :current_instances => 0,
        :target_instances => 0,
      }
    end

    total_samples = 0
    interval_started_at = Time.now.to_f
    while true
      begin
        haproxy_data = []
        @options.haproxy.map do |haproxy|
          Resolv.getaddresses(haproxy.host).each do |host|
            uri = haproxy.clone
            uri.host = host
            haproxy_data << sample(uri)
          end
        end
        aggregate_haproxy_data(haproxy_data)

        update_current_marathon_instances

        calculate_target_instances

        if total_samples >= @options.samples
          scale_list = build_scaling_list
          if !scale_list.empty?
            @log.info("#{scale_list.length} apps require scaling")
          else
            @log.info("Apps does not require scaling, please check the marathon-lb configuration if its an unexpected behaviour.")
          end

          scale_apps(scale_list)
        end

        total_samples += 1
      rescue Exception => msg
        @log.error("Caught exception: " + msg.to_s)
        @log.error(msg.backtrace)
      end
      STDOUT.flush
      sleep([0, (interval_started_at + @options.interval) - Time.now.to_f].max)
      interval_started_at = Time.now.to_f
    end
  end

  def parse_haproxy_header_labels(csv)
    header = csv.first[2..-2].split(/,/)
    # Enumerate the header
    header_labels = {}
    for i in 0..(header.length - 1)
      header_labels[i] = header[i]
    end
    header_labels
  end

  def parse_haproxy_frontends(csv, header_labels)
    csv = csv.select do |line|
      # Drop all lines which are empty or begin with # or empty
      !line.match(/^\s*#/) && !line.match(/^\s*$/)
    end
    samples = csv.map do |line|
      line.split(/,/)
    end.select do |line|
      line[1].match('FRONTEND')
    end

    frontends = {}
    samples.each do |sample|
      data = {}
      header_labels.each do |i,label|
        data[label.to_sym] = sample[i]
      end
      frontends[sample[0]] = data
    end
    frontends
  end

  def sample(haproxy)
    # Read from haproxy CSV endpoint
    req = Net::HTTP::Get.new('/haproxy?stats;csv')
    if !@options.haproxyCredentials.empty?
      req.basic_auth @options.haproxyCredentials[0], @options.haproxyCredentials[1]
    end

    res = Net::HTTP.new(haproxy.host,
                        haproxy.port).start do |http|
      http.request(req)
    end

    csv = res.body.split(/\r?\n/)

    header_labels = parse_haproxy_header_labels(csv)
    frontends = parse_haproxy_frontends(csv, header_labels)

    # Now we've got all the frontend data sampled in `frontends`
    frontends = frontends.select do |name|
      @options.apps.include?(name)
    end

    frontends
  end

  def aggregate_haproxy_data(haproxy_data)
    @apps.each do |app,data|
      if data[:rate].length >= @options.samples
        data[:rate].rotate!
        data[:rate].pop
      end
      rate = 0
      haproxy_data.each do |d|
        next if d[app].nil?
        rate += d[app][:rate].to_i + d[app][:qcur].to_i
      end
      data[:rate] << rate
      data[:rate_avg] =
        data[:rate].inject(0.0) { |sum,el| sum + el } / data[:rate].size
    end
  end

  def update_current_marathon_instances
    req = Net::HTTP::Get.new('/v2/apps')
    if !@options.marathonCredentials.empty?
      req.basic_auth @options.marathonCredentials[0], @options.marathonCredentials[1]
    end

    res = Net::HTTP.start(@options.marathon.host,
                          @options.marathon.port) {|http|
      http.request(req)
    }
    apps = JSON.parse(res.body)

    instances = {}
    apps['apps'].each do |app|
      id = app['id'][1..-1].gsub '/', '_' # trim leading '/'  # gsub add support for folders
      instances[id] = app['instances']
    end
    # Find our app backends
    @apps.each do |app,data|
      app_id = app.match(/(.*)_\d+$/)[1]
      if instances.has_key?(app_id)
        data[:current_instances] = instances[app_id]
      end
    end
  end

  def calculate_target_instances
    @apps.each do |app,data|
      data[:target_instances] =
        [(data[:rate_avg] / @options.target_rps).ceil, 1].max
    end
  end

  def build_scaling_list
    to_scale = {}
    @apps.each do |app,data|
      app_id = app.match(/(.*)_\d+$/)[1]
      app_id = app_id.dup.gsub '_', '/' # support for folders.

      # Scale if: the target and current instances don't match, we've exceed the
      # threshold difference, and a scale operation wasn't performed recently
      if data[:target_instances] == data[:current_instances]
        data[:intervals_past_threshold] = 0
        next
      end
      if ((data[:rate_avg] / data[:current_instances]) - @options.target_rps).abs.to_f / @options.target_rps < @options.threshold_percent &&
              (data[:target_instances] - data[:current_instances]).abs.to_f < @options.threshold_instances
        data[:intervals_past_threshold] = 0
        next
      end
      data[:intervals_past_threshold] += 1
      if data[:intervals_past_threshold] < @options.intervals_past_threshold
        next
      end

      if data[:last_scaled] + (@options.cooldown * @options.interval) +
               @options.interval * @options.samples >= Time.now.to_f
        @log.info("Not scaling #{app_id} yet because it needs to cool down (scaled #{(Time.now.to_f - data[:last_scaled]).round(1)}s ago)")
        @log.info("app_id=#{app_id} rate_avg=#{data[:rate_avg]}/#{data[:current_instances]} " +
                  "target_rps=#{@options.target_rps} current_rps=#{data[:rate_avg] / data[:current_instances]}")
        next
      end
      if to_scale.has_key?(app_id) && to_scale[app_id] > data[:target_instances]
        # If another frontend requires more instances than this one, do nothing
      else
        @log.info("Scaling #{app_id} from #{data[:current_instances]} to " +
                  "#{data[:target_instances]} instances")
        @log.info("app_id=#{app_id} rate_avg=#{data[:rate_avg]} " +
                  "target_rps=#{@options.target_rps} current_rps=#{data[:rate_avg] / data[:current_instances]}")
        to_scale[app_id] = data[:target_instances]
        data[:last_scaled] = Time.now.to_f
      end
    end
    to_scale
  end

  def scale_apps(scale_list)
    scale_list.each do |app,instances|
      req = Net::HTTP::Put.new('/v2/apps/' + app)
      if !@options.marathonCredentials.empty?
        req.basic_auth @options.marathonCredentials[0], @options.marathonCredentials[1]
      end
      req.content_type 'application/json'
      req.body = JSON.generate({'instances'=>instances})

      Net::HTTP.new(@options.marathon.host,
                    @options.marathon.port).start do |http|
        http.request(req)
      end
    end
  end
end

options = Optparser.parse(ARGV)
autoscale = Autoscale.new(options)
autoscale.run
