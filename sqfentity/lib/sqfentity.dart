//                           LICENSE

//    Copyright (C) 2019, HUSEYIN TOKPUNAR http://huseyintokpinar.com/

//    Download & Update Latest Version: https://github.com/hhtokpinar/sqfEntity

//    Licensed under the Apache License, Version 2.0 (the 'License');
//    you may not use this file except in compliance with the License.
//    You may obtain a copy of the License at

//     http://www.apache.org/licenses/LICENSE-2.0

//    Unless required by applicable law or agreed to in writing, software
//    distributed under the License is distributed on an 'AS IS' BASIS,
//    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//    See the License for the specific language governing permissions and
//    limitations under the License.

import 'dart:async' show Future;
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:sqfentity_gen/sqfentity_gen.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
//import 'package:sqflite/sqflite.dart';
import 'package:synchronized/synchronized.dart';

// BEGIN DATABASE PROVIDER

class SqfEntityProvider extends SqfEntityModelBase {
  SqfEntityProvider(SqfEntityModelProvider dbModel,
      {String tableName,
      String colId,
      List<String> primaryKeyList,
      String whereStr}) {
    _dbModel = dbModel;
    _tableName = tableName;
    _whereStr = whereStr;
    // _colId = colId; // removed after v1.3.0
    _primaryKeyList = primaryKeyList;
  }
  SqfEntityProvider._internal();
  static final SqfEntityProvider _sqfEntityProvider =
      SqfEntityProvider._internal();
  static SqfEntityProvider get = _sqfEntityProvider;
  String _tableName = '';
  //String _colId = ''; // removed after v1.3.0
  List<String> _primaryKeyList;
  String _whereStr;
  SqfEntityModelProvider _dbModel;
  static Map<String, Database> _dbMap;
  static Map<String, Batch> _openedBatch;

  static Map<String, Batch> get openedBatch {
    return _openedBatch = _openedBatch ?? <String, Batch>{};
  }

  Future<Database> get db async {
    _dbMap = _dbMap ?? <String, Database>{};
    if (_dbMap[_dbModel.databaseName] == null) {
      _dbMap[_dbModel.databaseName] = await openDb();
      await _dbModel.initializeDB();
      // if (!await _dbModel.initializeDB()) {
      //   _dbMap[_dbModel.databaseName] = null;
      //  }
      // Unfortunately SQLite doesn't support the ADD CONSTRAINT variant of the ALTER TABLE. Therefore we had to comment line below
      //await _dbModel.initializeForeignKeys();
    }
    return _dbMap[_dbModel.databaseName];
  }

  Future<void> writeDatabase(ByteData data) async {
    _dbMap[_dbModel.databaseName] = null;
    final List<int> bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    try {
      final dbpath = await _dbModel.getDatabasePath();
      final path = '$dbpath/${_dbModel.databaseName}';
      if (File(path).existsSync()) {
        await deleteDatabase(path);
        if (File('$path-wal').existsSync()) {
          File('$path-wal').deleteSync();
        }
      }
      File(path).writeAsBytesSync(bytes, mode: FileMode.write);
      print('The database has been written to $path successfully');
    } catch (e) {
      throw Exception(e.toString());
    }
  }

  /// When the software/app is started, sqfentity checks the database was it initialized. If needed, initilizeDb method runs that CREATE TABLE / ALTER TABLE ADD COLUMN queries for you.
  Future<Database> openDb() async {
    final lock = Lock();
    Database _db;
    await lock.synchronized(() async {
      final databasesPath = await getDatabasesPath();
      final path = join(databasesPath, _dbModel.databaseName);
      final file = File(path);

      // check if file exists
      if (!file.existsSync()) {
        // Copy from asset if MyDbModel.bundledDatabasePath is not empty
        if (_dbModel.bundledDatabasePath != null &&
            _dbModel.bundledDatabasePath != '' &&
            _dbModel.bundledDatabasePath != 'null') {
          final ByteData data =
              await rootBundle.load(_dbModel.bundledDatabasePath);
          await writeDatabase(data);
        }
      }
      //_db = await openDatabase(path, version: 1, onCreate: _createDb);

      _db = await openDatabase(path, version: 1, onCreate: _createDb, password: _dbModel.password);
      // }
    });
    //}
    return _db;
  }

  /// Creates db if not exist
  void _createDb(Database db, int version) async {
    await db.execute(
        'Create table sqfentitytables (id integer primary key, tablename text, version int, properties text)');
    await db.execute(
        'Create table sqfentitysequences (id text UNIQUE, value integer)');
    print('${_dbModel.databaseName} created successfully');
  }

  Future<dynamic> getById(List<dynamic> ids) async {
    if (ids == null) {
      return null;
    }
    final Database db = await this.db;

    final query = 'Select * from $_tableName where $_whereStr';
    final result = await db.rawQuery(query, ids);
    return result;
  }

  /// Run sql command with arguments (arguments is optional)
  Future<BoolResult> execSQL(String pSql, [List<dynamic> arguments]) async {
    final BoolResult result = BoolResult(success: false);

    try {
      if (openedBatch[_dbModel.databaseName] == null) {
        final Database db = await this.db;
        await db.execute(pSql, arguments);
        result
          ..success = true
          ..successMessage = 'sql command executed successfully';
      } else {
        openedBatch[_dbModel.databaseName].execute(pSql, arguments);
        result
          ..success = true
          ..successMessage = 'sql command added to batch successfully';
      }
    } catch (e) {
      result.errorMessage = e.toString();
    }

    return result;
  }

  /// Run sql command List
  Future<BoolCommitResult> execSQLList(List<String> pSql,
      {bool exclusive, bool noResult, bool continueOnError}) async {
    bool closeBatch = false;
    final result = BoolCommitResult(success: false);
    // If there is no open transaction, start one
    if (openedBatch[_dbModel.databaseName] == null) {
      await batchStart();
      closeBatch = true;
    }
    for (String sql in pSql) {
      openedBatch[_dbModel.databaseName].execute(sql);
    }
    if (closeBatch) {
      try {
        result
          ..commitResult = await batchCommit(
              exclusive: exclusive,
              noResult: noResult,
              continueOnError: continueOnError)
          ..success = true;
      } catch (e) {
        if (closeBatch) {
          openedBatch[_dbModel.databaseName] = null;
        }
        result.errorMessage = e.toString();
        print('SQFENTITY ERROR while run execSQLList:');
        print(result.toString());
      }
    } else {
      result.success = true;
    }
    return result;
  }

  Future<List<dynamic>> getForeignKeys(String tableName) async {
    final Database db = await this.db;
    final result = await db.rawQuery('PRAGMA foreign_key_list($tableName)');
    return result;
  }

  /// Run Select Command and return List<Map<String,dynamic>> such as datatable
  Future<List> execDataTable(String pSql, [List<dynamic> arguments]) async {
    final Database db = await this.db;
    final result = await db.rawQuery(pSql, arguments);
    return result;
  }

  /// Run Select Command and return first col of first row
  Future<dynamic> execScalar(String pSql, [List<dynamic> arguments]) async {
    final Database db = await this.db;
    if (!pSql.contains(' LIMIT ')) {
      pSql += ' LIMIT 1';
    }
    final result = await db.rawQuery(pSql, arguments);
    if (result.isNotEmpty)
    {  return result.first.values.first;}
    else
    {  return null;}
  }

  Future<List> toList(QueryParams params) async {
    final Database db = await this.db;
    final result = await db.query(_tableName,
        columns: params.selectColumns,
        where: params.whereString,
        whereArgs: params.whereArguments,
        orderBy: params.orderBy == '' ? null : params.orderBy,
        groupBy: params.groupBy == '' ? null : params.groupBy,
        limit: params.limit == 0 ? null : params.limit,
        offset: params.offset == 0 ? null : params.offset,
        distinct: params.distinct);
    // print('\r\n');
    // print('\r\n');

    // You can uncomment following print command for print when called db query with parameters automatically
    /*
    print('********** SqfEntityProvider.toList(QueryParams=> columns:' +
        (params.selectColumns != null ? params.selectColumns.toString() : '*') +
        ', whereString: ' +
        (params.whereString != null ? params.whereString : 'null') +
        ', whereArgs:' +
        (params.whereArguments != null
            ? params.whereArguments.toString()
            : 'null') +
        ', orderBy:' +
        (params.orderBy != '' ? params.orderBy : 'null') +
        ', groupBy:' +
        (params.groupBy != '' ? params.groupBy : 'null') +
        ')');
        */
    return result;
  }

  Future<BoolResult> delete(QueryParams params) async {
    final result = BoolResult();

    if ((params.limit != null && params.limit > 0) || (params.offset != null && params.offset >0)) {
      result
        ..success = false
        ..successMessage =
            'You can not use top() or page() function with delete() method';
      print(
          'SQFENTITY ERROR WHEN DELETE RECORDS: You can not use top() or page() function with delete() method');
      return result;
    }

    if (openedBatch[_dbModel.databaseName] == null) {
      final Database db = await this.db;
      try {
        final deletedItems = await db.delete(_tableName,
            where: params.whereString, whereArgs: params.whereArguments);
        result
          ..success = true
          ..successMessage = '$deletedItems items deleted';
      } catch (e) {
        result.errorMessage = e.toString();
      }
    } else {
      openedBatch[_dbModel.databaseName].delete(_tableName,
          where: params.whereString, whereArgs: params.whereArguments);
      result
        ..success = true
        ..successMessage = 'added to batch that item will be deleted';
    }

    return result;
  }

  Future<BoolResult> updateBatch(
      QueryParams params, Map<String, dynamic> values) async {
    final result = BoolResult();
    if (openedBatch[_dbModel.databaseName] == null) {
      try {
        final Database db = await this.db;
        final updatedItems = await db.update(_tableName, values,
            where: params.whereString, whereArgs: params.whereArguments);
        result
          ..success = true
          ..successMessage = '$updatedItems items updated';
      } catch (e) {
        result.errorMessage = e.toString();
      }
    } else {
      openedBatch[_dbModel.databaseName].update(_tableName, values,
          where: params.whereString, whereArgs: params.whereArguments);
      result
        ..success = true
        ..successMessage = 'added to batch that item(s) will be updated';
    }
    return result;
  }

  List<dynamic> buildWhereArgs(dynamic o) {
    final retVal = <dynamic>[];
    for (int i = 0; i < _primaryKeyList.length; i++) {
      retVal.add(o[_primaryKeyList[i]]);
    }
    return retVal;
  }

  Future<int> update(dynamic T) async {
    final o = await T.toMap(forQuery: true);
    try {
      if (openedBatch[_dbModel.databaseName] == null) {
        final Database db = await this.db;
        final result = await db.update(_tableName, o as Map<String, dynamic>,
            where: _whereStr, whereArgs: buildWhereArgs(o));
        T.saveResult = BoolResult(
            success: true,
            successMessage:
                '$_tableName-> ${_primaryKeyList[0]} = ${o[_primaryKeyList[0]]} saved successfully');
        return result;
      } else {
        openedBatch[_dbModel.databaseName].update(
            _tableName, o as Map<String, dynamic>,
            where: _whereStr, whereArgs: buildWhereArgs(o));
        T.saveResult = BoolResult(
            success: true,
            successMessage:
                '$_tableName-> update: added to batch successfully');
        return 0;
      }
    } catch (e) {
      T.saveResult = BoolResult(
          success: false,
          errorMessage: '$_tableName-> Save failed. Error: ${e.toString()}');
      return null;
    }
  }

  Future<int> insert(dynamic T) async {
    try {
      if (openedBatch[_dbModel.databaseName] == null) {
        final Database db = await this.db;
        final result = await db.insert(
            _tableName, await T.toMap(forQuery: true) as Map<String, dynamic>);
        T.saveResult = BoolResult(
            success: true,
            successMessage:
                '$_tableName-> ${_primaryKeyList[0]}=$result saved successfully');
        return result;
      } else {
        openedBatch[_dbModel.databaseName].insert(
            _tableName, await T.toMap(forQuery: true) as Map<String, dynamic>);
        return null;
      }
    } catch (e) {
      T.saveResult = BoolResult(
          success: false,
          errorMessage: '$_tableName-> Save failed. Error: ${e.toString()}');
      return null;
    }
  }

  Future<int> rawInsert(String pSql, List<dynamic> params) async {
    int result = 0;
    if (openedBatch[_dbModel.databaseName] == null) {
      final Database db = await this.db;
      result = await db.rawInsert(pSql, params);
    } else {
      openedBatch[_dbModel.databaseName].rawInsert(pSql, params);
    }
    return result;
  }

  Future<BoolCommitResult> rawInsertAll(String pSql, List<dynamic> params,
      {bool exclusive, bool noResult, bool continueOnError}) async {
    final result = BoolCommitResult(success: false);
    bool closeBatch = false;
    
    // If there is no open transaction, start one
    if (openedBatch[_dbModel.databaseName] == null) {
      await batchStart();
      closeBatch = true;
    }

    for (var t in params) {
      openedBatch[_dbModel.databaseName]
          .rawInsert(pSql, t.toArgsWithIds() as List<dynamic>);
    }

    if (closeBatch) {
      try {
        result
          ..commitResult = await batchCommit(
              exclusive: exclusive,
              noResult: noResult,
              continueOnError: continueOnError)
          ..success = true;
      } catch (e) {
        if (closeBatch) {
          openedBatch[_dbModel.databaseName] = null;
        }
        result.errorMessage = e.toString();
        print('SQFENTITY ERROR while run execSQLList:');
        print(result.toString());
      }
    } else {
      result.success = true;
    }

    return result;
  }

  Future<List<BoolResult>> saveAll(String pSql, List T) async {
    final results = <BoolResult>[];
    if (openedBatch[_dbModel.databaseName] == null) {
      final Database db = await this.db;
      for (var t in T) {
        final result = BoolResult(success: false);
        try {
          final o = await t.toMap(forQuery: true);
          if (o[_primaryKeyList[0]] != null) {
            final uresult =
                await db.rawInsert(pSql, t.toArgsWithIds() as List<dynamic>);
            if (uresult > 0) {
              result.successMessage =
                  'id=${o[_primaryKeyList[0]].toString()} upserted successfully';
            }
          } else {
            final iresult =
                await db.insert(_tableName, o as Map<String, dynamic>);
            if (iresult > 0) {
              result.successMessage =
                  'id=${iresult.toString()} inserted  successfully';
            }
          }
          result.success = true;
        } catch (e) {
          result
            ..successMessage = null
            ..errorMessage = e.toString();
        }
        results.add(result);
      }
    } else {
      for (var t in T) {
        final o = await t.toMap(forQuery: true);
        if (o[_primaryKeyList[0]] != null) {
          openedBatch[_dbModel.databaseName]
              .update(_tableName, o as Map<String, dynamic>);
        } else {
          openedBatch[_dbModel.databaseName]
              .insert(_tableName, o as Map<String, dynamic>);
        }
      }
    }

    return results;
  }

  Future<int> sequence(SqfEntitySequenceBase seq, bool increase,
      {bool reset = false}) async {
    final Database db = await this.db;
    if (reset) {
      await db.execute(
          'UPDATE sqfentitysequences SET value=${seq.startWith} where id=?',
          [seq.sequenceName]);
      return seq.startWith;
    }
    final resCurrent = await db.rawQuery(
        'SELECT value from sqfentitysequences where id=?', [seq.sequenceName]);
    final currentVal = resCurrent.first.values.first as int;
    if (!increase) {
      return currentVal;
    } else {
      final nextVal = currentVal + seq.incrementBy;
      if (nextVal >= seq.minValue && nextVal <= seq.maxValue) {
        await db.execute(
            'UPDATE sqfentitysequences SET value=$nextVal where id=?',
            [seq.sequenceName]);
        return nextVal;
      } else if (seq.cycle) {
        return sequence(seq, true, reset: true);
      } else {
        throw Exception(
            'SQFENTITIY: sequence (${seq.sequenceName}) exceeds its minValue or maxValue ');
      }
    }
  }

  Future<void> batchStart() async {
    if (openedBatch[_dbModel.databaseName] == null) {
      final Database db = await this.db;
      openedBatch[_dbModel.databaseName] = db.batch();
    }
  }

  Future<List<dynamic>> batchCommit(
      {bool exclusive, bool noResult, bool continueOnError}) async {
    if (openedBatch[_dbModel.databaseName] != null) {
      final retVal = await openedBatch[_dbModel.databaseName].commit(
          exclusive: exclusive,
          noResult: noResult,
          continueOnError: continueOnError);
      openedBatch[_dbModel.databaseName] = null;
      return retVal;
    } else {
      return null;
    }
  }

  void batchRollback() async {
    openedBatch[_dbModel.databaseName] = null;
  }
}
// END DATABASE PROVIDER

abstract class SqfEntityModelProvider extends SqfEntityModelBase {
  /// initializeDB is performed automatically in this version. You no longer need to call this method
  Future<bool> initializeDB() async {
    databaseTables = databaseTables ?? [];
    sequences = sequences ?? [];
    final dbSequences = sequences.where((i) => !i.initialized).toList();
    if (dbSequences.isNotEmpty) {
      final tableSquence = await SqfEntityProvider(this)
          .execDataTable('PRAGMA table_info(sqfentitysequences)');
      if (tableSquence == null || tableSquence.isEmpty) {
        await SqfEntityProvider(this).execSQL(
            'Create table sqfentitysequences (id text UNIQUE, value integer)');
      }
      for (SqfEntitySequenceBase sequence in dbSequences) {
        final sqRow = await SqfEntityProvider(this).execDataTable(
            'SELECT * FROM sqfentitysequences WHERE id=?',
            [sequence.sequenceName]);
        if (sqRow.isEmpty) {
          await SqfEntityProvider(this).execSQL(
              'INSERT INTO sqfentitysequences (id, value) VALUES (?,?)',
              [sequence.sequenceName, sequence.startWith]);
        }
        sequence.initialized = true;
        print(
            'SQFENTITIY: Sequence [${sequence.sequenceName}] initialized successfully');
      }
    }
    final dbTables = databaseTables.where((i) => !i.initialized).toList();
    if (dbTables.isNotEmpty) {
      //List<String> updateQueryList = <String>[];
      for (SqfEntityTableBase table in dbTables) {
        // check existing table fields in the database
        final tableFields = await SqfEntityProvider(this)
            .execDataTable('PRAGMA table_info(${table.tableName})');
        final List<TableField> existingDBfields = <TableField>[];
        if (tableFields != null && tableFields.isNotEmpty) {
          String primaryKeyName;
          for (final row in tableFields) {
            if (row['pk'].toString() == '1') {
              primaryKeyName = row['name'].toString();
              break;
            }
          }
          primaryKeyName = primaryKeyName ?? tableFields[0]['name'].toString();
          if (!table.primaryKeyNames.contains(primaryKeyName)) {
            throw Exception(
                'SQFENTITIY: DATABASE INITIALIZE ERROR The primary key name \'$primaryKeyName\' for table named [${table.tableName}] must be in [${table.primaryKeyNames.join(',')}]');
          }
          final startIndex =
              table.primaryKeyName != null && table.primaryKeyName.isNotEmpty
                  ? 1
                  : 0;
          for (int i = startIndex; i < tableFields.length; i++) {
            existingDBfields.add(TableField(tableFields[i]['name'].toString(),
                parseDbType(tableFields[i]['type'].toString())));
          }
          // create SQL Command for new columns
          final List<String> alterTableColsQuery =
              checkTableColumns(table, existingDBfields);

          if (alterTableColsQuery.isNotEmpty) {
            print('SQFENTITIY: alterTableQuery => $alterTableColsQuery');

            final result =
                await SqfEntityProvider(this).execSQLList(alterTableColsQuery);
            if (result.success) {
              table.initialized = true;
              print(
                  'SQFENTITIY: Table named [${table.tableName}] was initialized successfully (Added new columns)');
              if (checkForIsReadyDatabase(dbTables)) {
                return true;
              }
            }
          } else {
            table.initialized = true;
            print(
                'SQFENTITIY: Table named [${table.tableName}] was initialized successfully (No added new columns)');
            if (checkForIsReadyDatabase(dbTables)) {
              return true;
            }
          }
        } else // The table if not exist
        {
          final createTable =
              await SqfEntityProvider(this).execSQL(table.createTableSQL);
          if (createTable.success) {
            final List<String> alterTableIndexesQuery =
                checkTableIndexes(table);
            table.initialized = true;
            print(
                'SQFENTITIY: Table named [${table.tableName}] was initialized successfully (created table)');
            if (checkForIsReadyDatabase(dbTables)) {
              return true;
            }
            if (alterTableIndexesQuery.isNotEmpty) {
              await SqfEntityProvider(this).execSQLList(alterTableIndexesQuery);
              print(
                  'SQFENTITIY: alterTableIndexesQuery => $alterTableIndexesQuery');
              await SqfEntityProvider(this).execSQLList(alterTableIndexesQuery);
            }
          } else // table can not created
          {
            print(createTable.toString());
            return false;
          }
        }
      }
    }

    return true;
  }

  /// CHECK FOREIGN KEYS
  Future<bool> initializeForeignKeys() async {
    // {id: 0, seq: 0, table: Employee, from: SupportRepId, to: EmployeeId, on_update: NO ACTION, on_delete: NO ACTION, match: NONE}
    // ALTER TABLE child ADD CONSTRAINT fk_child_parent FOREIGN KEY (parent_id) REFERENCES parent(id);
    // FOREIGN KEY(column_name) REFERENCES parent_table_name(reference_to)
    final alterTableQuery = <String>[];
    for (final table in databaseTables) {
      final rfields = table.fields
          .whereType<SqfEntityFieldRelationshipBase>()
          .toList();
      if (rfields.isNotEmpty) {
        final fKeys =
            await SqfEntityProvider(this).getForeignKeys(table.tableName);
        for (final rfield in rfields) {
          if (rfield is SqfEntityFieldRelationshipBase) {
            final fkeyExist = fKeys.isEmpty
                ? null
                : fKeys.singleWhere((f) => f['from'] == rfield.fieldName);
            if (fkeyExist == null) {
              final String tableName = rfield.table == null
                  ? table.tableName
                  : rfield.table.tableName;
              final String primaryKey = rfield.table == null
                  ? table.primaryKeyName
                  : rfield.table.primaryKeyName;
              alterTableQuery.add(
                  'ALTER TABLE ${table.tableName} ADD CONSTRAINT fk_${table.tableName}_${rfield.fieldName} FOREIGN KEY (${rfield.fieldName}) REFERENCES $tableName($primaryKey) ON DELETE ${rfield.deleteRule.toString().replaceAll('_VALUE', '').replaceAll('_', ' ').replaceAll('DeleteRule.', '')}');
            }
          }
        }
      }
    }
    if (alterTableQuery.isNotEmpty) {
      print('SQFENTITIY: alterTableIndexesQuery => $alterTableQuery');
      await SqfEntityProvider(this).execSQLList(alterTableQuery);
    }
    return true;
  }

  /// Send any Object or Object List such as a product or productList to json String
  Future<String> toJson(dynamic T) async {
    if (T is List) {
      final list = <dynamic>[];
      for (var o in T) {
        list.add(await o.toMap());
      }
      return json.encode(list);
    } else {
      return json.encode(await T.toMap());
    }
  }

  /// Run sql command with arguments (arguments is optional)
  Future<BoolResult> execSQL(String sql, [List<dynamic> arguments]) async {
    return SqfEntityProvider(this).execSQL(sql, arguments);
  }

  /// Write database on existing db (path=your new database path, byte= your new database's ByteData)
  Future<void> writeDatabase(ByteData data) async {
    return SqfEntityProvider(this).writeDatabase(data);
  }

  /// Run sql command List
  Future<BoolCommitResult> execSQLList(List<String> sql) async {
    return SqfEntityProvider(this).execSQLList(sql);
  }

  /// Run Select Command and return List<Map<String,dynamic>> such as datatable
  Future<List> execDataTable(String sql, [List<dynamic> arguments]) async {
    return SqfEntityProvider(this).execDataTable(sql, arguments);
  }

  /// Run Select Command and return first col of first row
  Future<dynamic> execScalar(String sql, [List<dynamic> arguments]) async {
    return SqfEntityProvider(this).execScalar(sql, arguments);
  }

  Future<String> getDatabasePath() async {
    return await getDatabasesPath();
  }

  void batchStart() {
    SqfEntityProvider(this).batchStart();
  }

  Future<List<dynamic>> batchCommit() async {
    return SqfEntityProvider(this).batchCommit();
  }

  void batchRollback() async {
    return SqfEntityProvider(this).batchRollback();
  }
}

/// check all tables is it ready
bool checkForIsReadyDatabase(List<SqfEntityTableBase> dbTables) {
  if (dbTables.where((i) => !i.initialized).isEmpty) {
    print('SQFENTITIY: The database is ready for use');
    return true;
  } else {
    return false;
  }
}

List<String> checkTableIndexes(SqfEntityTableBase table) {
  final alterTableQuery = <String>[];
  for (SqfEntityFieldType field in table.fields) {
    if (field is SqfEntityFieldRelationshipBase) {
      alterTableQuery.add(
          'CREATE INDEX IF NOT EXISTS IDX${field.relationshipName + field.fieldName} ON ${table.tableName} (${field.fieldName} ASC)');
    }
  }
  return alterTableQuery;
}

List<String> checkTableColumns(
    SqfEntityTableBase table, List<TableField> existingDBfields) {
  final alterTableQuery = <String>[];
  for (var newField in table.fields) {
    if (newField is SqfEntityFieldVirtualBase) {
      continue;
    }
    final eField = existingDBfields.where(
        (x) => x.fieldName.toLowerCase() == newField.fieldName.toLowerCase());
    if (eField.isNotEmpty) {
      // if (newField.dbType == DbType.bool) newField.dbType = DbType.numeric;
      if (!(newField.dbType == DbType.bool &&
              eField.toList()[0].fieldType == DbType.numeric) &&
          eField.toList()[0].fieldType != newField.dbType) {
        print(
            // throw Exception(
            'SQFENTITIY DATABASE INITIALIZE ERROR: The type of column [${newField.fieldName}(${newField.dbType.toString()})] does not match the existing column [${eField.toList()[0].fieldName}(${eField.toList()[0].fieldType.toString()})] on the table (${table.tableName})');
      }
    } else {
      alterTableQuery.add(
          'ALTER TABLE ${table.tableName} ADD COLUMN ${newField.toSqLiteFieldString()}');
      if (newField.defaultValue != null) {
        setDefaultValue(newField);
        if (newField.defaultValue != null) {
          alterTableQuery.add(
              'UPDATE ${table.tableName} set ${newField.fieldName}=${newField.defaultValue}');
        }
      }
      if (newField is SqfEntityFieldRelationshipBase) {
        alterTableQuery.add(
            'CREATE INDEX IF NOT EXISTS IDX${newField.relationshipName + newField.fieldName} ON ${table.tableName} (${newField.fieldName} ASC)');
      }
    }
  }
  return alterTableQuery;
}

void setDefaultValue(SqfEntityFieldType newField) {
  switch (newField.dbType) {
    case DbType.text:
      newField.defaultValue = "'${newField.defaultValue}'";
      break;
    case DbType.bool:
      newField.defaultValue = newField.defaultValue == true ? 1 : 0;
      break;
    case DbType.date:
      newField.defaultValue =
          newField.defaultValue.toString().contains('DateTime.now()')
              ? 'date(\'now\')'
              : null;
      break;
    case DbType.datetime:
    case DbType.datetimeUtc:
      newField.defaultValue =
          newField.defaultValue.toString().contains('DateTime.now()')
              ? 'datetime(\'now\')'
              : null;
      break;
    default:
    // return its value
  }
}

class BundledModelBase extends SqfEntityModelProvider {}

Future<SqfEntityModelBase> convertDatabaseToModelBase(
    {String databaseName,
    String bundledDatabasePath,
    List<String> databaseTables}) async {
  final bundledModelBase = BundledModelBase()
    ..bundledDatabasePath = bundledDatabasePath
    ..databaseName = databaseName;

  final bundledDbModel = SqfEntityProvider(bundledModelBase);

  final tableList = await bundledDbModel
      //.execDataTable('SELECT name,type FROM sqlite_master WHERE type=\'table\' or type=\'view\'');
      .execDataTable(
          'SELECT name,type FROM sqlite_master WHERE type=\'table\' ${databaseTables != null && databaseTables.isNotEmpty ? " AND name IN (\'${databaseTables.join('\',\'')}\')" : ""}');
  print(
      'SQFENTITY.convertDatabaseToModelBase---------------${tableList.length} tables and views found in $bundledDatabasePath database:');
  printList(tableList);

  DeleteRule getDeleteRule(String rule) {
    switch (rule) {
      case 'NO ACTION':
        return DeleteRule.NO_ACTION;
        break;
      case 'CASCADE':
        return DeleteRule.CASCADE;
        break;
      case 'SET DEFAULT VALUE':
        return DeleteRule.SET_DEFAULT_VALUE;
        break;
      case 'SET NULL':
        return DeleteRule.SET_NULL;
        break;
      default:
        return DeleteRule.NO_ACTION;
    }
  }

  final tables = <SqfEntityTableBase>[];
  for (final table in tableList) {
    if ([
      'android_metadata',
      'sqfentitytables',
      'sqfentitysequences',
      'sqlite_sequence'
    ].contains(table['name'].toString())) {
      continue;
    }
    final tableName = table['name'].toString();
    String primaryKeyName;
    final List<String> primaryKeyNames = <String>[];
    bool isIdentity = false;
    bool isPrimaryKeyText = false;
    // check fields in the table
    final tableFields = await SqfEntityProvider(bundledModelBase)
        .execDataTable('PRAGMA table_info($tableName)');
    final existingDBfields = <SqfEntityFieldType>[];
    if (tableFields != null && tableFields.isNotEmpty) {
      // check primary key in the table
      for (final row in tableFields) {
        if (row['pk'].toString() != '0') {
          primaryKeyName = row['name'].toString();
          isPrimaryKeyText = row['type'].toString().toLowerCase() == 'text';
          primaryKeyNames.add(primaryKeyName);
          final isAutoIncrement = SqfEntityProvider(bundledModelBase).execScalar(
              'SELECT "is-autoincrement" FROM sqlite_master WHERE tbl_name="$tableName" AND sql LIKE "%AUTOINCREMENT%"');

          isIdentity = isAutoIncrement != null;
          //break;
        }
      }
      primaryKeyName = primaryKeyName ?? tableFields[0]['name'].toString();
      // convert table fields to SqfEntityField

      for (int i = 0; i < tableFields.length; i++) {
        if (tableFields[i]['name'].toString() != primaryKeyName) {
          existingDBfields.add(SqfEntityFieldBase(
              tableFields[i]['name'].toString(),
              parseDbType(tableFields[i]['type'].toString()),
              isPrimaryKeyField:
                  primaryKeyNames.contains(tableFields[i]['name'])));
        }
      }
    }
    tables.add(SqfEntityTableBase()
      ..tableName = tableName
      ..modelName = toCamelCase(tableName)
      ..primaryKeyName = primaryKeyName
      ..primaryKeyType = isPrimaryKeyText
          ? PrimaryKeyType.text
          : isIdentity
              ? PrimaryKeyType.integer_auto_incremental
              : PrimaryKeyType.integer_unique
      ..fields = existingDBfields
      ..primaryKeyNames.add(primaryKeyName)
      ..primaryKeyTypes.add('int'));
  }

  // set RelationShips
  for (var table in tables) {
    final relationFields = <SqfEntityFieldRelationshipBase>[];
    final foreignKeys = await bundledDbModel.getForeignKeys(table.tableName);
    if (foreignKeys.isNotEmpty) {
      print(
          'SQFENTITY.convertDatabaseToModelBase---------------${foreignKeys.length} foreign keys found in $bundledDatabasePath/${table.tableName}:');
      printList(foreignKeys);
      // Customer:
      // {id: 0, seq: 0, table: Employee, from: SupportRepId, to: EmployeeId, on_update: NO ACTION, on_delete: NO ACTION, match: NONE}
      // Employee:
      // {id: 0, seq: 0, table: Employee, from: ReportsTo, to: EmployeeId, on_update: NO ACTION, on_delete: NO ACTION, match: NONE}
      for (final fKey in foreignKeys) {
        for (final parentTable in tables) {
          if (parentTable.tableName.toLowerCase() ==
              fKey['table'].toString().toLowerCase()) {
            // bir foreign key, primary key olarak ayarlanmışsa relationship alanına dönüştür
            if (table.primaryKeyName.toLowerCase() ==
                fKey['from'].toString().toLowerCase()) {
              relationFields.add(SqfEntityFieldRelationshipBase(
                  parentTable, getDeleteRule(fKey['on_delete'].toString()))
                ..fieldName = table.primaryKeyName
                ..isPrimaryKeyField = true
                ..dbType = table.primaryKeyType == PrimaryKeyType.text
                    ? DbType.text
                    : DbType.integer);
              table
                ..primaryKeyName = ''
                ..primaryKeyType = null;
            }
            for (final field in table.fields) {
              if (field.fieldName.toLowerCase() ==
                  fKey['from'].toString().toLowerCase())
               { relationFields.add(SqfEntityFieldRelationshipBase(
                    parentTable, getDeleteRule(fKey['on_delete'].toString()))
                  ..fieldName = field.fieldName
                  ..dbType = field.dbType);}
            }
          }
        }
        //print(fKey.toString());

      }
    } else {
      for (final field in table.fields) {
        if (field.fieldName.toLowerCase() != 'id' &&
            (field.dbType == DbType.integer ||
                field.dbType == DbType.numeric)) {
          for (final parentTable in tables) {
            if (parentTable.tableName != table.tableName &&
                ((parentTable.primaryKeyName.toLowerCase() ==
                        field.fieldName.toLowerCase()) ||
                    ('${parentTable.tableName}${parentTable.primaryKeyName}'
                            .toLowerCase() ==
                        field.fieldName.toLowerCase()))) {
              print(
                  'relationship column (${field.fieldName}) found on the table s${parentTable.tableName}');
              //table.fields.add(
              relationFields.add(SqfEntityFieldRelationshipBase(
                  parentTable, DeleteRule.NO_ACTION)
                ..fieldName = field.fieldName
                ..dbType = field.dbType);
              //table.fields.remove(field);
            }
          }
        }
      }
    }
    if (relationFields.isNotEmpty) {
      for (final relationField in relationFields) {
        try {
          final field = table.fields
              .singleWhere((f) => f.fieldName == relationField.fieldName);
          relationField.isPrimaryKeyField = field.isPrimaryKeyField;
          table.fields.remove(field);
        } catch (e) {
          print(e.toString());
        }
        table.fields.add(relationField);
      }
    }
  }

  // SET MANY TO MANY RELATIONS
  final manyToManyTables = <SqfEntityTableBase>[];
  for (var table in tables) {
    if (table.fields.length == 2 &&
        table.fields
                .whereType<SqfEntityFieldRelationshipBase>()
                .length ==
            2) {
      final ref = table.fields[0] as SqfEntityFieldRelationshipBase;
      final referred = table.fields[1] as SqfEntityFieldRelationshipBase;
      ref.table.fields
          .add(SqfEntityFieldRelationshipBase(referred.table, ref.deleteRule)
            ..fieldName = 'm${table.tableName}'
            ..manyToManyTableName = table.tableName
            ..relationType = RelationType.MANY_TO_MANY);
      table.relationType = RelationType.MANY_TO_MANY;
      //tables.remove(table);
      manyToManyTables.add(table);
    }
  }
  //for (var table in manyToManyTables) {
  //  tables.remove(table);
  //}

  return ConvertedModel()
    ..databaseName = databaseName
    ..modelName = toModelName(databaseName.replaceAll('.', ''), null)
    ..databaseTables = tables
    ..bundledDatabasePath = null; //bundledDatabasePath;
}

void printList(List<dynamic> list) {
  for (final o in list) {
    print(o.toString());
  }
}
