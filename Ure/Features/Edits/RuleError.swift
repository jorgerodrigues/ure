import Foundation

// An error that a rule of the library gives, such as one open job per watch, or a record that is
// archived or gone. The same edit gets the same answer each time it runs, so Try Again can't get
// past it. A disk or database error is not one: it can pass, so it stops the queue.
nonisolated protocol RuleError: Error {}

nonisolated extension ArchiveError: RuleError {}
nonisolated extension CaliberValidationError: RuleError {}
nonisolated extension ChecklistError: RuleError {}
nonisolated extension EditRefusal: RuleError {}
nonisolated extension JobError: RuleError {}
nonisolated extension JobValidationError: RuleError {}
nonisolated extension LinkError: RuleError {}
nonisolated extension MaterialError: RuleError {}
nonisolated extension PartError: RuleError {}
nonisolated extension PartValidationError: RuleError {}
nonisolated extension WatchError: RuleError {}
nonisolated extension WatchValidationError: RuleError {}
