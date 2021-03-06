/*
 * Copyright IBM Corporation 2016
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

extension RouterRequest {

    class MimeTypeAcceptor {

        /// Finds the full mime type for a given extension.
        ///
        /// - Parameter forExtension: mime type extension String.
        /// - Returns: the full mime type.
        private static func getMimeType(forExtension ext: String) -> String {
            if let mimeType = ContentType.sharedInstance.getContentType(forExtension: ext) {
                return mimeType
            }
            return ext
        }

        typealias MimeTypeWithQValue = (type: String, qValue: Double, qValueRaw: String)

        /// Parse MIME type string into a digestable tuple format.
        ///
        /// - Parameter mediaType: Raw MIME type String.
        /// - Returns: A tuple with the MIME type and q parameter value if present, qValue defaults to 1.
        private static func parse(mediaType type: String) -> MimeTypeWithQValue {
            var finishedPair = ("", 1.0, "1.0")
            let trimmed = type.trimmingCharacters(in: CharacterSet.whitespaces)
            let components = trimmed.characters.split(separator: ";").map(String.init)

            if let mediaType = components.first {
                finishedPair.0 = mediaType
            }

            if let qPreference = components.last {
                let qualityComponents = qPreference.characters.split(separator: "=").map(String.init)
                if let q = qualityComponents.first, let value = qualityComponents.last, q == "q",
                    let pairValue = Double(value) {
                    finishedPair.1 = pairValue
                    finishedPair.2 = value
                }
            }

            return finishedPair
        }

        /// Checks if passed in content types are acceptable based on the request's Accept header
        /// field values
        ///
        /// - Parameter headerValues: Array of Accept header values.
        /// - Parameter types: Array of content/mime type strings.
        /// - Parameter matchAllPattern: Special header value that matches all types. For example "*" or "*/*"
        /// - Returns: Most acceptable type or nil if there are none
        static func accepts(headerValues: [String], types: [String], matchAllPattern: String) -> String? {
            let criteriaMatches = getCriteriaMatches(headerValues: headerValues, types: types, matchAllPattern: matchAllPattern)

            // sort by priority and by qValue to determine best type to return
            let sortedMatches = Array(criteriaMatches).sorted {
                if $0.1.priority != $1.1.priority {
                    return $0.1.priority < $1.1.priority
                } else if $0.1.qValueRaw != $1.1.qValueRaw {
                    return $0.1.qValue > $1.1.qValue
                } else {
                    return $0.1.headerOrder < $1.1.headerOrder
                }
            }

            if let bestMatch = sortedMatches.first {
                return bestMatch.0
            }
            return nil
        }

        private typealias CriteriaMatches = [String : (priority: Int, qValue: Double, qValueRaw: String, headerOrder: Int)]

        private static func getCriteriaMatches(headerValues: [String], types: [String], matchAllPattern: String) -> CriteriaMatches {
            var criteriaMatches = [String : (priority: Int, qValue: Double, qValueRaw: String, headerOrder: Int)]()

            for (headerOrder, rawHeaderValue) in headerValues.enumerated() {
                for type in types {
                    handleMatch(rawHeaderValue: rawHeaderValue, type: type, matchAllPattern: matchAllPattern,
                                criteriaMatches: &criteriaMatches, headerOrder: headerOrder)
                }
            }
            return criteriaMatches
        }

        private static func handleMatch(rawHeaderValue: String, type: String, matchAllPattern: String,
                                        criteriaMatches: inout CriteriaMatches, headerOrder: Int) {
            let parsedHeaderValue = parse(mediaType: rawHeaderValue)
            let headerType = parsedHeaderValue.type
            guard !headerType.isEmpty && parsedHeaderValue.qValue > 0.0 else {
                // quality value of 0 indicates not acceptable
                return
            }

            let mimeType = getMimeType(forExtension: type)

            func setMatch(withPriority priority: Int, qValue: Double, qValueRaw: String, in criteriaMatches: inout CriteriaMatches) {
                criteriaMatches[type] = (priority: priority, qValue: qValue, qValueRaw: qValueRaw, headerOrder: headerOrder)
            }

            // type and optional subtype match, e.g. text/html == text/html  or  gzip == gzip
            if headerType == mimeType {
                setMatch(withPriority: 1, qValue: parsedHeaderValue.qValue, qValueRaw: parsedHeaderValue.qValueRaw, in: &criteriaMatches)
                return
            }

            if headerType == matchAllPattern {
                if criteriaMatches[type] == nil { // else do nothing
                    setMatch(withPriority: 3, qValue: parsedHeaderValue.qValue, qValueRaw: parsedHeaderValue.qValueRaw, in: &criteriaMatches)
                }
                return
            }

            if headerType.hasSuffix("/*") {
                let index = headerType.index(headerType.endIndex, offsetBy: -1)
                let headerTypePrefix = headerType.substring(to: index) // strip the trailing *

                if mimeType.hasPrefix(headerTypePrefix) {
                    // type/* match, e.g. mimeType: text/html matches headerType: text/*
                    if let match = criteriaMatches[type] {
                        if match.priority > 2 {
                            setMatch(withPriority: 2, qValue: parsedHeaderValue.qValue, qValueRaw: parsedHeaderValue.qValueRaw, in: &criteriaMatches)
                        }
                    } else {
                        setMatch(withPriority: 2, qValue: parsedHeaderValue.qValue, qValueRaw: parsedHeaderValue.qValueRaw, in: &criteriaMatches)
                    }
                }
            }
        }
    }
}
