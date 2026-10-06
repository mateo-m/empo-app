require 'zlib'
PSDK_PLATFORM = :windows
PSDK_VERSION = File.read('pokemonsdk/version.txt').to_i
RELEASE_PATH = 'Release'
module ScriptLoader
  PROJECT_SCRIPT_PATH = File.expand_path('scripts')
  VSCODE_SCRIPT_PATH = File.expand_path('pokemonsdk/scripts')
  SCRIPT_FOLDER_REG = %r{/[0-9]+[ _][^/]+/$}i
end
def load_data(f) = Marshal.load(File.binread(f))
Dir.mkdir('Release') unless Dir.exist?('Release')
Dir.mkdir('Release/Data') unless Dir.exist?('Release/Data')
c = 'pokemonsdk/scripts/tools/Compilation/'
require "./#{c}project_compilation_utils"
require "./#{c}project_compilation_scripts"
require "./#{c}project_compilation_game_rb"
include ProjectCompilation
collector = ScriptCollector.new(ScriptCollector.script_class)
saver = ScriptCollector::ScriptSaver.new(collector.collect_scripts([ScriptLoader::PROJECT_SCRIPT_PATH]))
saver.save('Release/Data/Scripts.dat')
ScriptCollector::GameRb.new.write_files
puts "DONE #{RUBY_DESCRIPTION}"
