/*
 * Copyright (c) 2026 EKA2L1 Team
 *
 * This file is part of EKA2L1 project.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

#include <services/centralrepo/repo.h>
#include <services/internet/commsdat.h>

#include <common/algorithm.h>
#include <common/log.h>

#include <algorithm>
#include <string>
#include <vector>

namespace eka2l1::epoc::internet {
    namespace {
        // CommsDat squeezes a whole database into a flat central repository keyspace. Every key
        // is <TableId><FieldId><RecordId><Attributes>, one byte-ish each (see commsdat.h in any
        // Symbian SDK). Record 0 is the hidden template a table is cloned from, record 0xFF holds
        // the table's own schema description, and field 0x7F stands for "the record itself" -
        // that is the key clients enumerate a table with.
        enum : std::uint32_t {
            TABLE_MASK = 0x7F800000,
            FIELD_SHIFT = 16,
            RECORD_SHIFT = 8,
            RECORD_MASK = 0x0000FF00,

            FIELD_RECORD_TAG = 0x01,
            FIELD_RECORD_NAME = 0x02,
            FIELD_RECORD_SELF = 0x7F,

            RECORD_TEMPLATE = 0x00,
            RECORD_TYPE_INFO = 0xFF,

            ATTRIBUTE_HIDDEN = 0x20,

            // A record is also mirrored with the top bit set. CommsDat keeps that mirror as the
            // index it walks a table through, so a record only exists once both are present.
            KEY_INDEX_BIT = 0x80000000
        };

        enum : std::uint32_t {
            TABLE_NETWORK = 0x01800000,
            TABLE_LOCATION = 0x02000000,
            TABLE_IAP = 0x02800000,
            TABLE_MODEM_BEARER = 0x08000000,
            TABLE_OUTGOING_GPRS = 0x0C800000
        };

        // IAP table fields. The service/bearer ones name a table and then point at a record in it.
        enum : std::uint32_t {
            FIELD_IAP_SERVICE_TYPE = 0x03,
            FIELD_IAP_SERVICE = 0x04,
            FIELD_IAP_BEARER_TYPE = 0x05,
            FIELD_IAP_BEARER = 0x06,
            FIELD_IAP_NETWORK = 0x07,
            FIELD_IAP_NETWORK_WEIGHTING = 0x08,
            FIELD_IAP_LOCATION = 0x09
        };

        enum : std::uint32_t {
            FIELD_GPRS_APN = 0x03,
            FIELD_MODEM_BEARER_IF_NAME = 0x03
        };

        // Shown wherever the guest lists connection methods.
        static const char16_t *ACCESS_POINT_NAME = u"EKA2L1";
        static const char16_t *ACCESS_POINT_APN = u"internet";

        std::uint32_t make_key(const std::uint32_t table, const std::uint32_t field, const std::uint32_t record,
            const std::uint32_t attributes = 0) {
            return table | (field << FIELD_SHIFT) | (record << RECORD_SHIFT) | attributes;
        }

        std::uint32_t record_of(const std::uint32_t key) {
            return (key & RECORD_MASK) >> RECORD_SHIFT;
        }

        bool in_table(const std::uint32_t key, const std::uint32_t table) {
            return !(key & KEY_INDEX_BIT) && ((key & TABLE_MASK) == table);
        }

        /// True when the table holds a record a client would actually be offered.
        bool has_real_record(central_repo &repo, const std::uint32_t table) {
            for (const central_repo_entry &entry : repo.entries) {
                if (in_table(entry.key, table)) {
                    const std::uint32_t record = record_of(entry.key);

                    if ((record != RECORD_TEMPLATE) && (record != RECORD_TYPE_INFO)) {
                        return true;
                    }
                }
            }

            return false;
        }

        /// Lowest record id in the table that is not yet taken, ignoring template/schema records.
        std::uint32_t first_free_record(central_repo &repo, const std::uint32_t table) {
            std::vector<bool> taken(RECORD_TYPE_INFO, false);

            for (const central_repo_entry &entry : repo.entries) {
                if (in_table(entry.key, table)) {
                    const std::uint32_t record = record_of(entry.key);

                    if ((record != RECORD_TEMPLATE) && (record != RECORD_TYPE_INFO)) {
                        taken[record] = true;
                    }
                }
            }

            for (std::uint32_t record = 1; record < RECORD_TYPE_INFO; record++) {
                if (!taken[record]) {
                    return record;
                }
            }

            return 0;
        }

        /// Text fields are stored as raw UTF-16LE bytes, exactly as they travel over IPC.
        std::u16string field_string(central_repo &repo, const std::uint32_t table, const std::uint32_t field,
            const std::uint32_t record) {
            for (const std::uint32_t attributes : { 0u, static_cast<std::uint32_t>(ATTRIBUTE_HIDDEN) }) {
                central_repo_entry *entry = repo.find_entry(make_key(table, field, record, attributes));

                if (entry && (entry->data.etype == central_repo_entry_type::string)) {
                    return std::u16string(reinterpret_cast<const char16_t *>(entry->data.strd.data()),
                        entry->data.strd.length() / sizeof(char16_t));
                }
            }

            return std::u16string();
        }

        void put_int(central_repo &repo, const std::uint32_t key, const std::uint64_t value) {
            central_repo_entry_variant variant;
            variant.etype = central_repo_entry_type::integer;
            variant.intd = value;

            if (!repo.add_new_entry(key, variant)) {
                central_repo_entry *existing = repo.find_entry(key);
                existing->data = variant;
            }
        }

        void put_string(central_repo &repo, const std::uint32_t key, const std::u16string &value) {
            central_repo_entry_variant variant;
            variant.etype = central_repo_entry_type::string;
            variant.strd.assign(reinterpret_cast<const char *>(value.data()), value.length() * sizeof(char16_t));

            if (!repo.add_new_entry(key, variant)) {
                central_repo_entry *existing = repo.find_entry(key);
                existing->data = variant;
            }
        }

        /**
         * \brief Bring a record into existence.
         *
         * On top of its fields a record needs the "record itself" key and the index mirror of it.
         * The value behind those is a per-table stamp the ROM assigns, so reuse whatever the table
         * already carries rather than inventing one.
         */
        void declare_record(central_repo &repo, const std::uint32_t table, const std::uint32_t record) {
            std::uint64_t stamp = 0;

            for (const central_repo_entry &entry : repo.entries) {
                if (in_table(entry.key, table) && (((entry.key >> FIELD_SHIFT) & 0x7F) == FIELD_RECORD_SELF)
                    && (entry.data.etype == central_repo_entry_type::integer)) {
                    stamp = entry.data.intd;
                    break;
                }
            }

            put_int(repo, make_key(table, FIELD_RECORD_SELF, record), stamp);
            put_int(repo, KEY_INDEX_BIT | make_key(table, FIELD_RECORD_SELF, record),
                KEY_INDEX_BIT | make_key(table, FIELD_RECORD_SELF, record));

            // A table nobody ever wrote to has no schema marker either.
            const std::uint32_t type_info_key = make_key(table, FIELD_RECORD_SELF, RECORD_TYPE_INFO);

            if (!repo.find_entry(type_info_key)) {
                put_string(repo, type_info_key, std::u16string());
                put_int(repo, KEY_INDEX_BIT | type_info_key, KEY_INDEX_BIT | type_info_key);
            }
        }

        /// Copy the table's hidden template record onto a fresh record, dropping the hidden flag.
        void clone_template(central_repo &repo, const std::uint32_t table, const std::uint32_t record) {
            std::vector<central_repo_entry> cloned;

            for (const central_repo_entry &entry : repo.entries) {
                if (in_table(entry.key, table) && (record_of(entry.key) == RECORD_TEMPLATE)) {
                    const std::uint32_t field = (entry.key >> FIELD_SHIFT) & 0x7F;

                    if (field == FIELD_RECORD_SELF) {
                        continue;
                    }

                    central_repo_entry clone = entry;
                    clone.key = make_key(table, field, record);

                    cloned.push_back(clone);
                }
            }

            for (const central_repo_entry &entry : cloned) {
                if (!repo.find_entry(entry.key)) {
                    repo.entries.push_back(entry);
                }
            }
        }

        /**
         * \brief Pick the modem bearer a packet-data access point should ride on.
         *
         * Every 9.x ROM ships a handful; the packet-data one is bound to the generic NIF rather
         * than to PPP over a serial port. Any real record will do otherwise - the emulator never
         * acts on the bearer, it only has to be something the guest can read back.
         */
        std::uint32_t choose_modem_bearer(central_repo &repo) {
            std::uint32_t fallback = 0;

            for (const central_repo_entry &entry : repo.entries) {
                if (!in_table(entry.key, TABLE_MODEM_BEARER)) {
                    continue;
                }

                const std::uint32_t record = record_of(entry.key);

                if ((record == RECORD_TEMPLATE) || (record == RECORD_TYPE_INFO)) {
                    continue;
                }

                if (common::compare_ignore_case(field_string(repo, TABLE_MODEM_BEARER, FIELD_MODEM_BEARER_IF_NAME,
                                                    record),
                        std::u16string(u"genericnif"))
                    == 0) {
                    return record;
                }

                if (!fallback || (record < fallback)) {
                    fallback = record;
                }
            }

            return fallback;
        }

        /// Lowest existing real record of a table, 0 when the table has none.
        std::uint32_t first_real_record(central_repo &repo, const std::uint32_t table) {
            std::uint32_t found = 0;

            for (const central_repo_entry &entry : repo.entries) {
                if (!in_table(entry.key, table)) {
                    continue;
                }

                const std::uint32_t record = record_of(entry.key);

                if ((record == RECORD_TEMPLATE) || (record == RECORD_TYPE_INFO)) {
                    continue;
                }

                if (!found || (record < found)) {
                    found = record;
                }
            }

            return found;
        }
    }

    void provision_default_access_point(central_repo &repo) {
        if (repo.uid != COMMSDAT_REPO_UID) {
            return;
        }

        if (has_real_record(repo, TABLE_IAP)) {
            return;
        }

        const std::uint32_t iap_record = first_free_record(repo, TABLE_IAP);
        const std::uint32_t service_record = first_free_record(repo, TABLE_OUTGOING_GPRS);
        const std::uint32_t bearer_record = choose_modem_bearer(repo);

        if (!iap_record || !service_record || !bearer_record) {
            // An access point pointing at a bearer that does not exist is worse than none at all:
            // the guest would offer it and then fail somewhere much deeper.
            LOG_WARN(SERVICE_INTERNET, "CommsDat cannot host an emulator access point, leaving it alone");
            return;
        }

        // The service record carries the connection's IP settings. Cloning the ROM template keeps
        // every field the guest may read populated with values that ROM itself considers sane.
        clone_template(repo, TABLE_OUTGOING_GPRS, service_record);
        put_int(repo, make_key(TABLE_OUTGOING_GPRS, FIELD_RECORD_TAG, service_record), service_record);
        put_string(repo, make_key(TABLE_OUTGOING_GPRS, FIELD_RECORD_NAME, service_record), ACCESS_POINT_NAME);
        put_string(repo, make_key(TABLE_OUTGOING_GPRS, FIELD_GPRS_APN, service_record), ACCESS_POINT_APN);
        declare_record(repo, TABLE_OUTGOING_GPRS, service_record);

        std::uint32_t network_record = first_real_record(repo, TABLE_NETWORK);

        if (!network_record) {
            network_record = first_free_record(repo, TABLE_NETWORK);
            put_int(repo, make_key(TABLE_NETWORK, FIELD_RECORD_TAG, network_record), network_record);
            put_string(repo, make_key(TABLE_NETWORK, FIELD_RECORD_NAME, network_record), ACCESS_POINT_NAME);
            declare_record(repo, TABLE_NETWORK, network_record);
        }

        put_int(repo, make_key(TABLE_IAP, FIELD_RECORD_TAG, iap_record), iap_record);
        put_string(repo, make_key(TABLE_IAP, FIELD_RECORD_NAME, iap_record), ACCESS_POINT_NAME);
        put_string(repo, make_key(TABLE_IAP, FIELD_IAP_SERVICE_TYPE, iap_record), u"OutgoingGPRS");
        put_int(repo, make_key(TABLE_IAP, FIELD_IAP_SERVICE, iap_record), service_record);
        put_string(repo, make_key(TABLE_IAP, FIELD_IAP_BEARER_TYPE, iap_record), u"ModemBearer");
        put_int(repo, make_key(TABLE_IAP, FIELD_IAP_BEARER, iap_record), bearer_record);
        put_int(repo, make_key(TABLE_IAP, FIELD_IAP_NETWORK, iap_record), network_record);
        put_int(repo, make_key(TABLE_IAP, FIELD_IAP_NETWORK_WEIGHTING, iap_record), 0);

        const std::uint32_t location_record = first_real_record(repo, TABLE_LOCATION);

        if (location_record) {
            put_int(repo, make_key(TABLE_IAP, FIELD_IAP_LOCATION, iap_record), location_record);
        }

        declare_record(repo, TABLE_IAP, iap_record);

        // Real CommsDat persists are key-ordered. Keep it that way now that records were appended,
        // so a table still reads back record by record.
        std::stable_sort(repo.entries.begin(), repo.entries.end(),
            [](const central_repo_entry &lhs, const central_repo_entry &rhs) {
                return lhs.key < rhs.key;
            });

        LOG_INFO(SERVICE_INTERNET, "Added a default internet access point to CommsDat (IAP {}, service {}, bearer {})",
            iap_record, service_record, bearer_record);
    }
}
