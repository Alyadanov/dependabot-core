# frozen_string_literal: true

require "toml-rb"
require "open3"
require "shellwords"
require "dependabot/shared_helpers"
require "dependabot/python/version"
require "dependabot/python/requirement"
require "dependabot/python/python_versions"
require "dependabot/python/file_updater"
require "dependabot/python/native_helpers"

module Dependabot
  module Python
    class FileUpdater
      class PoetryFileUpdater
        require_relative "pyproject_preparer"

        attr_reader :dependencies, :dependency_files, :credentials

        def initialize(dependencies:, dependency_files:, credentials:)
          @dependencies = dependencies
          @dependency_files = dependency_files
          @credentials = credentials
        end

        def updated_dependency_files
          return @updated_dependency_files if @update_already_attempted

          @update_already_attempted = true
          @updated_dependency_files ||= fetch_updated_dependency_files
        end

        private

        def dependency
          # For now, we'll only ever be updating a single dependency
          dependencies.first
        end

        def fetch_updated_dependency_files
          updated_files = []

          if file_changed?(pyproject)
            updated_files <<
              updated_file(
                file: pyproject,
                content: updated_pyproject_content
              )
          end

          if lockfile && lockfile.content == updated_lockfile_content
            raise "Expected lockfile to change!"
          end

          if lockfile
            updated_files <<
              updated_file(file: lockfile, content: updated_lockfile_content)
          end

          updated_files
        end

        def updated_pyproject_content
          dependencies.
            select { |dep| requirement_changed?(pyproject, dep) }.
            reduce(pyproject.content.dup) do |content, dep|
              updated_requirement =
                dep.requirements.find { |r| r[:file] == pyproject.name }.
                fetch(:requirement)

              old_req =
                dep.previous_requirements.
                find { |r| r[:file] == pyproject.name }.
                fetch(:requirement)

              updated_content =
                content.gsub(declaration_regex(dep)) do |line|
                  line.gsub(old_req, updated_requirement)
                end

              raise "Content did not change!" if content == updated_content

              updated_content
            end
        end

        def updated_lockfile_content
          @updated_lockfile_content ||=
            begin
              new_lockfile = updated_lockfile_content_for(prepared_pyproject)

              tmp_hash =
                TomlRB.parse(new_lockfile)["metadata"]["content-hash"]
              correct_hash = pyproject_hash_for(updated_pyproject_content)

              new_lockfile.gsub(tmp_hash, correct_hash)
            end
        end

        def prepared_pyproject
          @prepared_pyproject ||=
            begin
              content = updated_pyproject_content
              content = sanitize(content)
              content = freeze_other_dependencies(content)
              content = freeze_dependencies_being_updated(content)
              content = add_private_sources(content)
              content
            end
        end

        def freeze_other_dependencies(pyproject_content)
          PyprojectPreparer.
            new(pyproject_content: pyproject_content, lockfile: lockfile).
            freeze_top_level_dependencies_except(dependencies)
        end

        def freeze_dependencies_being_updated(pyproject_content)
          pyproject_object = TomlRB.parse(pyproject_content)
          poetry_object = pyproject_object.fetch("tool").fetch("poetry")

          dependencies.each do |dep|
            %w(dependencies dev-dependencies).each do |type|
              names = poetry_object[type]&.keys || []
              pkg_name = names.find { |nm| normalise(nm) == dep.name }
              next unless pkg_name

              if poetry_object[type][pkg_name].is_a?(Hash)
                poetry_object[type][pkg_name]["version"] = dep.version
              else
                poetry_object[type][pkg_name] = dep.version
              end
            end
          end

          TomlRB.dump(pyproject_object)
        end

        def add_private_sources(pyproject_content)
          PyprojectPreparer.
            new(pyproject_content: pyproject_content).
            replace_sources(credentials)
        end

        def sanitize(pyproject_content)
          PyprojectPreparer.
            new(pyproject_content: pyproject_content).
            sanitize
        end

        def updated_lockfile_content_for(pyproject_content)
          SharedHelpers.in_a_temporary_directory do
            write_temporary_dependency_files(pyproject_content)

            if python_version && !pre_installed_python?(python_version)
              run_poetry_command(%w(pyenv install -s) + [python_version])
              run_poetry_command(%w(pyenv exec pip install --upgrade pip))
              run_poetry_command(%w(pyenv exec pip install -r) +
                                 [NativeHelpers.python_requirements_path])
            end

            run_poetry_command(
              %w(pyenv exec poetry update) + [dependency.name, "--lock"]
            )

            return File.read("poetry.lock") if File.exist?("poetry.lock")

            File.read("pyproject.lock")
          end
        end

        def run_poetry_command(cmd_parts)
          command = Shellwords.join(cmd_parts)
          start = Time.now
          stdout, process = Open3.capture2e(command)
          time_taken = Time.now - start

          # Raise an error with the output from the shell session if Pipenv
          # returns a non-zero status
          return if process.success?

          raise SharedHelpers::HelperSubprocessFailed.new(
            message: stdout,
            error_context: {
              command: command,
              time_taken: time_taken,
              process_exit_value: process.to_s
            }
          )
        end

        def write_temporary_dependency_files(pyproject_content)
          dependency_files.each do |file|
            path = file.name
            FileUtils.mkdir_p(Pathname.new(path).dirname)
            File.write(path, file.content)
          end

          # Overwrite the .python-version with updated content
          File.write(".python-version", python_version) if python_version

          # Overwrite the pyproject with updated content
          File.write("pyproject.toml", pyproject_content)
        end

        def python_version
          pyproject_object = TomlRB.parse(prepared_pyproject)
          poetry_object = pyproject_object.dig("tool", "poetry")

          requirement =
            poetry_object&.dig("dependencies", "python") ||
            poetry_object&.dig("dev-dependencies", "python")

          return python_version_file_version unless requirement

          requirements = Python::Requirement.requirements_array(requirement)

          PythonVersions::SUPPORTED_VERSIONS.find do |version|
            requirements.any? do |r|
              r.satisfied_by?(Python::Version.new(version))
            end
          end
        end

        def python_version_file_version
          file_version = python_version_file&.content&.strip

          return unless file_version
          return unless pyenv_versions.include?("#{file_version}\n")

          file_version
        end

        def pyenv_versions
          @pyenv_versions ||= run_poetry_command(%w(pyenv install --list"))
        end

        def pre_installed_python?(version)
          PythonVersions::PRE_INSTALLED_PYTHON_VERSIONS.include?(version)
        end

        def pyproject_hash_for(pyproject_content)
          SharedHelpers.in_a_temporary_directory do |dir|
            File.write(File.join(dir, "pyproject.toml"), pyproject_content)
            SharedHelpers.run_helper_subprocess(
              command: "pyenv exec python #{NativeHelpers.python_helper_path}",
              function: "get_pyproject_hash",
              args: [dir]
            )
          end
        end

        def declaration_regex(dep)
          escaped_name = Regexp.escape(dep.name).gsub("\\-", "[-_.]")
          /(?:^|["'])#{escaped_name}["']?\s*=.*$/i
        end

        def file_changed?(file)
          dependencies.any? { |dep| requirement_changed?(file, dep) }
        end

        def requirement_changed?(file, dependency)
          changed_requirements =
            dependency.requirements - dependency.previous_requirements

          changed_requirements.any? { |f| f[:file] == file.name }
        end

        def updated_file(file:, content:)
          updated_file = file.dup
          updated_file.content = content
          updated_file
        end

        # See https://www.python.org/dev/peps/pep-0503/#normalized-names
        def normalise(name)
          name.downcase.gsub(/[-_.]+/, "-")
        end

        def pyproject
          @pyproject ||=
            dependency_files.find { |f| f.name == "pyproject.toml" }
        end

        def lockfile
          @lockfile ||= pyproject_lock || poetry_lock
        end

        def pyproject_lock
          dependency_files.find { |f| f.name == "pyproject.lock" }
        end

        def poetry_lock
          dependency_files.find { |f| f.name == "poetry.lock" }
        end

        def python_version_file
          dependency_files.find { |f| f.name == ".python-version" }
        end
      end
    end
  end
end
