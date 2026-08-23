# Thin wrapper over build.sh — see that script for what each step actually does.
.PHONY: run app build check doctor reset clean

run:
	@./build.sh run

app:
	@./build.sh app

build:
	@./build.sh build

check:
	@swift run RiskWarningChecks
	@swift run PrivacyChecks
	@swift run UsageStatsChecks

doctor:
	@./build.sh doctor

# Revoke Pour's Accessibility/Microphone grants to re-test the permission flow.
reset:
	@./build.sh reset

clean:
	@./build.sh clean
