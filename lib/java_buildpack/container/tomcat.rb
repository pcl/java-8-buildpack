# Encoding: utf-8
# Cloud Foundry Java Buildpack
# Copyright 2013 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'java_buildpack/component/modular_component'
require 'java_buildpack/container'
require 'java_buildpack/container/tomcat/tomcat_insight_support'
require 'java_buildpack/container/tomcat/tomcat_instance'
require 'java_buildpack/container/tomcat/tomcat_lifecycle_support'
require 'java_buildpack/container/tomcat/tomcat_logging_support'
require 'java_buildpack/container/tomcat/tomcat_access_logging_support'
require 'java_buildpack/container/tomcat/tomcat_redis_store'
require 'json'

module JavaBuildpack
  module Container

    # Encapsulates the detect, compile, and release functionality for Tomcat applications.
    class Tomcat < JavaBuildpack::Component::ModularComponent

      alias :super_compile :compile

      def compile
        super_compile
        fetch_dependencies
      end

      protected

      # (see JavaBuildpack::Component::ModularComponent#command)
      def command
        @droplet.java_opts.add_system_property 'http.port', '$PORT'

        [
          @droplet.java_home.as_env_var,
          @droplet.java_opts.as_env_var,
          "$PWD/#{(@droplet.sandbox + 'bin/catalina.sh').relative_path_from(@droplet.root)}",
          'run'
        ].flatten.compact.join(' ')
      end

      # (see JavaBuildpack::Component::ModularComponent#sub_components)
      def sub_components(context)
        [
          TomcatInstance.new(sub_configuration_context(context, 'tomcat')),
          TomcatLifecycleSupport.new(sub_configuration_context(context, 'lifecycle_support')),
          TomcatLoggingSupport.new(sub_configuration_context(context, 'logging_support')),
          TomcatAccessLoggingSupport.new(sub_configuration_context(context, 'access_logging_support')),
          TomcatRedisStore.new(sub_configuration_context(context, 'redis_store')),
          TomcatInsightSupport.new(context)
        ]
      end

      # (see JavaBuildpack::Component::ModularComponent#supports?)
      def supports?
        web_inf? && !JavaBuildpack::Util::JavaMainUtils.main_class(@application)
      end

      private

      def web_inf?
        (@application.root + 'WEB-INF').exist?
      end

      def maven_archive?
        dependencies_file.exist?
      end

      def dependencies_file
        lib_dir + 'maven-dependencies.json'
      end

      def lib_dir
        @application.root + 'WEB-INF/lib/'
      end

      def fetch_dependencies
        if !File.exist?("#{Dir.home}/.m2")
          Dir.mkdir("#{Dir.home}/.m2")
        end

        start = Time.new
        depsFile = File.read(dependencies_file)
        deps = JSON.parse(depsFile)
        deps['dependencies'].each { |dep|
          group = dep['groupId']
          artifact = dep['artifactId']
          version = dep['version']
          sha = dep['sha1']

          groupDirs = group.gsub('.', '/')
          artifactPath = "#{Dir.home}/.m2/repository/#{groupDirs}/#{artifact}/#{version}/#{artifact}-#{version}.jar"
          if !File.exist?(artifactPath)
            # fetch the dependency from the internet
            puts "fetching #{artifact}"
            results = `mvn dependency:get -Dartifact=#{group}:#{artifact}:#{version}`
            if !File.exist?(artifactPath)
              puts "Error fetching artifact! Details:"
              puts results
            end
          end
          
          # validate the sha1 hash
          actualsha = Digest::SHA1.file(artifactPath).hexdigest
          if actualsha != sha
            raise "SHA-1 mismatch for #{group}:#{artifact}:#{version}! Expected '#{sha}'; got '#{actualsha}'"
          end
          
          # make a symlink from the right spot in the lib dir to the target
          # TODO support for custom repository location env variable; classifiers
          FileUtils.ln_s(artifactPath, lib_dir)
        }
        puts "Fetched maven dependencies in #{Time.new - start} seconds"
      end

    end

  end
end
