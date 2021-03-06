require 'pathname'

require 'librarian/helpers/debug'
require 'librarian/support/abstract_method'

require 'librarian/version'
require 'librarian/dependency'
require 'librarian/manifest_set'
require 'librarian/particularity'
require 'librarian/resolver'
require 'librarian/source'
require 'librarian/spec_change_set'
require 'librarian/specfile'
require 'librarian/lockfile'
require 'librarian/ui'

module Librarian
  extend self

  include Support::AbstractMethod
  include Helpers::Debug

  class Error < StandardError
  end

  attr_accessor :ui

  abstract_method :specfile_name, :dsl_class, :install_path

  def project_path
    @project_path ||= begin
      root = Pathname.new(Dir.pwd)
      root = root.dirname until root.join(specfile_name).exist? || root.dirname == root
      path = root.join(specfile_name)
      path.exist? ? root : nil
    end
  end

  def specfile_path
    project_path.join(specfile_name)
  end

  def specfile
    Specfile.new(self, specfile_path)
  end

  def lockfile_name
    "#{specfile_name}.lock"
  end

  def lockfile_path
    project_path.join(lockfile_name)
  end

  def lockfile
    Lockfile.new(self, lockfile_path)
  end

  def ephemeral_lockfile
    Lockfile.new(self, nil)
  end

  def resolver
    Resolver.new(self)
  end

  def cache_path
    project_path.join('tmp/librarian/cache')
  end

  def project_relative_path_to(path)
    Pathname.new(path).relative_path_from(project_path)
  end

  def spec_change_set(spec, lock)
    SpecChangeSet.new(self, spec, lock)
  end

  def ensure!
    unless project_path
      raise Error, "Cannot find #{specfile_name}!"
    end
  end

  def clean!
    if cache_path.exist?
      debug { "Deleting #{project_relative_path_to(cache_path)}" }
      cache_path.rmtree
    end
    if install_path.exist?
      install_path.children.each do |c|
        debug { "Deleting #{project_relative_path_to(c)}" }
        c.rmtree unless c.file?
      end
    end
    if lockfile_path.exist?
      debug { "Deleting #{project_relative_path_to(lockfile_path)}" }
      lockfile_path.rmtree
    end
  end

  def install!
    resolve!
    manifests = ManifestSet.sort(lockfile.load(lockfile_path.read).manifests)
    manifests.each do |manifest|
      manifest.source.cache!([manifest])
    end
    install_path.mkpath unless install_path.exist?
    manifests.each do |manifest|
      manifest.install!
    end
  end

  def update!(dependency_names)
    unless lockfile_path.exist?
      raise Error, "Lockfile missing!"
    end
    previous_resolution = lockfile.load(lockfile_path.read)
    partial_manifests = ManifestSet.deep_strip(previous_resolution.manifests, dependency_names)
    debug { "Precaching Sources:" }
    previous_resolution.sources.each do |source|
      debug { "  #{source}" }
    end
    spec = specfile.read(previous_resolution.sources)
    spec_changes = spec_change_set(spec, previous_resolution)
    raise Error, "Cannot update when the specfile has been changed." unless spec_changes.same?
    resolution = resolver.resolve(spec, partial_manifests)
    unless resolution.correct?
      ui.info { "Could not resolve the dependencies." }
    else
      lockfile_text = lockfile.save(resolution)
      debug { "Bouncing #{lockfile_name}" }
      bounced_lockfile_text = lockfile.save(lockfile.load(lockfile_text))
      unless bounced_lockfile_text == lockfile_text
        debug { "lockfile_text: \n#{lockfile_text}"}
        debug { "bounced_lockfile_text: \n#{bounced_lockfile_text}"}
        raise Error, "Cannot bounce #{lockfile_name}!"
      end
      lockfile_path.open('wb') { |f| f.write(lockfile_text) }
    end
  end

  def resolve!(options = {})
    if options[:force] || !lockfile_path.exist?
      spec = specfile.read
      manifests = []
    else
      lock = lockfile.read
      debug { "Precaching Sources:" }
      lock.sources.each do |source|
        debug { "  #{source}" }
      end
      spec = specfile.read(lock.sources)
      changes = spec_change_set(spec, lock)
      if changes.same?
        debug { "The specfile is unchanged: nothing to do." }
        return
      end
      manifests = changes.analyze
    end

    resolution = resolver.resolve(spec, manifests)
    unless resolution.correct?
      raise Error, "Could not resolve the dependencies."
    else
      lockfile_text = lockfile.save(resolution)
      debug { "Bouncing #{lockfile_name}" }
      bounced_lockfile_text = lockfile.save(lockfile.load(lockfile_text))
      unless bounced_lockfile_text == lockfile_text
        debug { "lockfile_text: \n#{lockfile_text}"}
        debug { "bounced_lockfile_text: \n#{bounced_lockfile_text}"}
        raise Error, "Cannot bounce #{lockfile_name}!"
      end
      lockfile_path.open('wb') { |f| f.write(lockfile_text) }
    end
  end

  def dsl(&block)
    dsl_class.run(&block)
  end

  def dsl_class
    self::Dsl
  end

private

  def root_module
    self
  end

end
