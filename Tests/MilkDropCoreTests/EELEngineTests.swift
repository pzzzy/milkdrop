import XCTest
@testable import MilkDropCore

final class EELEngineTests: XCTestCase {
    func testAssignmentsFunctionsAndPersistentVariables() throws {
        var engine = try EELEngine(source: "q1=2;q2=if(above(bass,1),q1*3,sin(pi/2));counter=counter+1;")
        var vars = ["bass": 2.0]
        try engine.execute(variables: &vars)
        XCTAssertEqual(vars["q2"], 6)
        XCTAssertEqual(vars["counter"], 1)
        vars["bass"] = 0
        try engine.execute(variables: &vars)
        XCTAssertEqual(vars["q2"]!, 1, accuracy: 0.0001)
        XCTAssertEqual(vars["counter"], 2)
    }
}
