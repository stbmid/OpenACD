require 'rake/clean'

INCLUDE = "include"

ERLC_FLAGS = "-I#{INCLUDE} +warn_unused_vars +warn_unused_import"

SRC = FileList['src/*.erl']
OBJ = SRC.pathmap("%{src,ebin}X.beam").reject{|x| x.include? 'test_coverage'}
DEBUGOBJ = SRC.pathmap("%{src,debug_ebin}X.beam")
COVERAGE = SRC.pathmap("%{src,coverage}X.txt")

@maxwidth = SRC.map{|x| File.basename(x, 'erl').length}.max

CLEAN.include("ebin/*.beam")
CLEAN.include("debug_ebin/*.beam")
CLEAN.include("coverage/*.txt")
CLEAN.include("coverage/*.html")

verbose(true)

directory 'ebin'
directory 'debug_ebin'
directory 'coverage'

rule ".beam" => ["%{ebin,src}X.erl"] do |t|
	sh "erlc -pa ebin -W #{ERLC_FLAGS} -o ebin #{t.source} "
end

rule ".beam" => ["%{debug_ebin,src}X.erl"] do |t|
	sh "erlc +debug_info -D EUNIT -pa debug_ebin -W #{ERLC_FLAGS} -o debug_ebin #{t.source} "
end

# this almost works, doesn't handle module dependancies though :(
rule ".txt" => ["%{coverage,debug_ebin}X.beam", 'debug_ebin/test_coverage.beam'] do |t|
	next if t.source.include? 'test_coverage'
	mod = File.basename(t.source, '.beam')
	maxwidth = 30
	test_output = `erl -pa debug_ebin -sname testpx -s test_coverage start #{mod} -run init stop`
	if /\*failed\*/ =~ test_output
		puts test_output.split("\n")[1..-1].map{|x| x.include?('1>') ? x.gsub(/\([a-zA-Z0-9\-@]+\)1>/, '') : x}.join("\n")
	else
		test_output[/1>\s*(.*)\n/]
		puts "  #{mod.ljust(@maxwidth - 1)} : #{$1}"
	end
end


task :compile => ['ebin'] + OBJ

task :default => :compile

task :release => :compile

desc "Alias for test:all"
task :test => "test:all"

namespace :test do
	desc "Compile .beam files with -DEUNIT and +debug_info => debug_ebin"
	task :compile => ['debug_ebin'] + DEBUGOBJ

	desc "run eunit tests, the dialyzer and output coverage reports"
	task :all => [:compile, :eunit, :dialyzer, :report_coverage]

	desc "run only the eunit tests"
	task :eunit =>  ['coverage'] + COVERAGE
	#end

	desc "report the percentage code coverage of the last test run"
	task :report_coverage =>  [:eunit] do
		global_total = 0
		files = Dir['coverage/*.txt']
		maxwidth = files.map{|x| File.basename(x, ".txt").length}.max
		puts "Code coverage:"
		files.each do |file|
			total = 0
			tally = 0
			File.read(file).each do |line|
				if line =~ /^\s+[1-9][0-9]*\.\./
					total += 1
					tally += 1
				elsif line =~ /^\s+0\.\./ and not line =~ /^-module/
					total += 1
				end
			end
			puts "  #{File.basename(file, ".txt").ljust(maxwidth)} : #{sprintf("%.2f%%", (tally/(total.to_f)) * 100)}"
			global_total += (tally/(total.to_f)) * 100
		end
		puts "Overall coverage: #{sprintf("%.2f%%", global_total/files.length)}"
	end

	desc "run the dialyzer"
	task :dialyzer do
		print "running dialyzer..."
		`dialyzer --check_plt`
		if $?.exitstatus != 0
			puts 'no PLT'
			puts "The dialyzer can't find the initial PLT, you can try building one using `rake build_plt`. This can take quite some time."
			exit(1)
		end
		STDOUT.flush
		dialyzer_output = `dialyzer --src -I include -c #{SRC.reject{|x| x =~ /test_coverage/}.join(' ')}`
		#puts dialyzer_output
		if $?.exitstatus.zero?
			puts 'ok'
		else
			puts 'not ok'
			puts dialyzer_output
		end
	end

	desc "try to create the dialyzer's initial PLT"
	task :build_plt do
		out = `which erlc`
		foo = out.split('/')[0..-3].join('/')+'/lib/erlang/lib'
		sh "dialyzer --build_plt -r #{foo}/kernel*/ebin #{foo}/stdlib*/ebin #{foo}/mnesia*/ebin"
	end
end
