import Foundation
import Combine
import SwiftUI // For Color used in GroupSettings/createDefaultGroups

// MARK: - Simulation Engine (Focused on State and Prediction)
class SimulationEngine: ObservableObject {

    // MARK: Core State Properties
    @Published var parameters: SimulationParameters = SimulationParameters()
    @Published var groupSettings: [GroupSettings] = SimulationEngine.createDefaultGroups(count: 3)

    // MARK: - Initialization
    init() {
        // Ensure parameters match initial group settings count
        parameters.numberOfGroups = self.groupSettings.count
        // Set default target if none exists
        if parameters.targetGroupID == nil, let firstGroupId = groupSettings.first?.id {
            parameters.targetGroupID = firstGroupId
        }
        // Load any saved profiles on init
        loadProfiles()
    }

    // Helper to create default groups
    static func createDefaultGroups(count: Int) -> [GroupSettings] {
        var groups: [GroupSettings] = []
        let numToCreate = max(1, min(count, GroupSettings.maxGroups))
        for i in 0..<numToCreate {
            var newGroup = GroupSettings()
            newGroup.name = "Group \(i + 1)"
            // Use the correct static constant from GroupSettings model
            newGroup.color = GroupSettings.predefinedColorsData[i % GroupSettings.predefinedColorsData.count]
            groups.append(newGroup)
        }
        return groups
    }

    // MARK: - Core Calculation Logic
    // Calculates the population state for the *next* month based on the current state.
    private func calculateNextPopulationState(currentPopulations: [UUID: Double]) -> [UUID: Double] {
        var nextPopulations = currentPopulations

        // 1. Apply Deaths
        for group in groupSettings {
            guard let currentPop = nextPopulations[group.id], currentPop > 0 else { continue }
            let lifeExpectancyYears = max(1.0, group.avgLifeExpectancy)
            let monthlyDeathRate = 1.0 / (lifeExpectancyYears * 12.0)
            let deaths = currentPop * monthlyDeathRate
            nextPopulations[group.id]? -= deaths
        }

        // 2. Apply Births (Simplified Model)
        for group in groupSettings {
            // Ensure population is positive after deaths before calculating births
            guard let currentPop = nextPopulations[group.id], currentPop > 0 else { continue }
            let settings = group

            // Simplified estimations for reproductive population segments
            let childBearingYears = 15.0
            let lifeExpectancyYears = max(1.0, settings.avgLifeExpectancy)
            let proportionFemale = settings.femaleRatio
            let proportionInChildBearingAge = min(1.0, childBearingYears / max(childBearingYears, lifeExpectancyYears * proportionFemale))
            let potentialMothers = currentPop * proportionFemale * proportionInChildBearingAge * (1.0 - settings.percentNotMarried)

            let marriageableAgeSpan = 15.0
            let proportionMale = settings.sexRatioMale
            let proportionMarriageableAge = min(1.0, marriageableAgeSpan / max(marriageableAgeSpan, lifeExpectancyYears * proportionMale))
            let potentialFathers = currentPop * proportionMale * proportionMarriageableAge * (1.0 - settings.percentNotMarried)

            // Simplified marriage model (internal only for this calculation)
            let maxWives = Double(max(1, settings.maxWives))
            let availableWomen = potentialMothers
            let potentialMenSlots = potentialFathers * maxWives
            let internallyMarriedWomen: Double
            if potentialMenSlots >= availableWomen {
                internallyMarriedWomen = availableWomen
            } else {
                internallyMarriedWomen = potentialMenSlots // Limited by men
            }

            // Calculate births based on TFR (avgChildrenPerWoman)
            let avgChildrenPerWomanLifetime = settings.avgChildrenPerWoman
            // Approximate monthly birth rate per *potentially* married woman in childbearing age
            let monthlyBirthRatePerWoman = avgChildrenPerWomanLifetime / (childBearingYears * 12.0)
            let births = internallyMarriedWomen * monthlyBirthRatePerWoman
            let newBirths = max(0, births) // Ensure non-negative births

            nextPopulations[group.id]? += newBirths

            // Final check to prevent negative population after births/deaths
            if let pop = nextPopulations[group.id], pop < 0 {
                nextPopulations[group.id] = 0
            }
        }
        return nextPopulations
    }

    // MARK: - Population Prediction Function
    // Calculates the population state at a specific future date without storing history.
    func predictPopulation(at futureDate: Date) -> [PopulationSnapshot]? {
        // Validate inputs
        guard !groupSettings.isEmpty else {
            print("Prediction Error: No groups configured.")
            return nil
        }
        guard futureDate >= parameters.startDate else {
            print("Prediction Error: Future date must be on or after start date.")
            // Allow prediction for the start date itself (returns initial state)
            if Calendar.current.isDate(futureDate, equalTo: parameters.startDate, toGranularity: .month) {
                 return groupSettings.map { PopulationSnapshot(groupID: $0.id, totalPopulation: Double($0.initialPopulation)) }
            }
            return nil // Invalid date
        }

        // Calculate number of monthly steps required
        guard let monthsToSimulate = Calendar.current.dateComponents([.month], from: parameters.startDate, to: futureDate).month,
              monthsToSimulate >= 0 else {
            print("Prediction Error: Could not calculate months between dates.")
            return nil
        }

        // If predicting for month 0, return initial state
        if monthsToSimulate == 0 {
            return groupSettings.map { PopulationSnapshot(groupID: $0.id, totalPopulation: Double($0.initialPopulation)) }
        }

        print("Predicting population for \(formatMonthYear(futureDate)) (\(monthsToSimulate) months from start)...")

        // Initialize prediction state from initial populations
        var predictedPopulations: [UUID: Double] = [:]
        for group in groupSettings {
             predictedPopulations[group.id] = Double(group.initialPopulation)
        }

        // Run simulation steps internally (synchronously)
        // For very long predictions, consider background execution (Task)
        for _ in 0..<monthsToSimulate {
            predictedPopulations = calculateNextPopulationState(currentPopulations: predictedPopulations)
        }

        // Format result into PopulationSnapshot array
        let predictionSnapshots = predictedPopulations.map { PopulationSnapshot(groupID: $0.key, totalPopulation: $0.value) }

        print("Prediction complete.")
        return predictionSnapshots
    }

    // MARK: - Settings Management (Retained for Loading Data)

    // Apply loaded settings (used by loadSelectedProfile)
    // Minimal version - just updates state and resets target if needed
    func applySettings(parameters: SimulationParameters, groupSettings: [GroupSettings]) {
        // Directly update the published properties
        self.groupSettings = groupSettings
        self.parameters = parameters

        // Ensure consistency after applying
        self.parameters.numberOfGroups = self.groupSettings.count
        if let targetId = self.parameters.targetGroupID, !self.groupSettings.contains(where: { $0.id == targetId }) {
             self.parameters.targetGroupID = self.groupSettings.first?.id // Reset target if invalid
        } else if self.parameters.targetGroupID == nil, !self.groupSettings.isEmpty {
             self.parameters.targetGroupID = self.groupSettings.first?.id // Set target if nil
        }
        // No simulation reset needed here as we removed the running simulation state
        print("Settings Applied for Prediction/Display.")
    }

    // Properties and functions for loading saved profiles
    @Published var savedProfiles: [SavedSettingsProfile] = []
    @Published var selectedProfileId: UUID?

    func loadProfiles() {
        savedProfiles = PersistenceController.shared.loadProfiles().sorted { $0.dateSaved > $1.dateSaved }
        print("Profiles loaded successfully.")
    }

    func loadSelectedProfile() {
        guard let profileId = selectedProfileId,
              let profileToLoad = savedProfiles.first(where: { $0.id == profileId })
        else {
            print("No profile selected to load.")
            // Optionally update status message if it were retained
            return
        }
        // Apply the loaded settings
        applySettings(parameters: profileToLoad.parameters, groupSettings: profileToLoad.groupSettings)
        print("Settings profile '\(profileToLoad.name)' loaded.")
        // Optionally update status message if it were retained
    }

    // Save/Delete functionality could also be added back if needed,
    // but are removed here as they aren't strictly required for just *calculating* predictions.

} // End class SimulationEngine
