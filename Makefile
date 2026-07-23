PACKAGE := Packages/TelemetryCore

.PHONY: spike test clean

spike:
	cd $(PACKAGE) && swift build --product smcspike

test:
	cd $(PACKAGE) && swift test

clean:
	cd $(PACKAGE) && swift package clean
